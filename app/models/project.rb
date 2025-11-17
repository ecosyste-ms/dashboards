class Project < ApplicationRecord
  include Stats
  include EcosystemsApiClient

  has_many :collection_projects, dependent: :destroy
  has_many :active_collection_projects, -> { active }, class_name: 'CollectionProject'
  has_many :collections, through: :active_collection_projects
  has_many :sourced_collections, class_name: 'Collection', foreign_key: 'source_project_id', dependent: :nullify

  has_many :user_projects, dependent: :destroy
  has_many :users, through: :user_projects

  has_many :issues, dependent: :delete_all
  has_many :commits, dependent: :delete_all
  has_many :tags, dependent: :delete_all
  has_many :packages, dependent: :delete_all
  has_many :advisories, dependent: :delete_all

  belongs_to :collective, optional: true

  validates :url, presence: true, uniqueness: { case_sensitive: false }
  validates :url, format: { without: /\Apkg:/, message: "cannot be a PURL (Package URL)" }
  validates :slug, presence: true, uniqueness: { case_sensitive: false }
  validates :slug, format: { 
    with: /\A[a-zA-Z0-9._-]+\/[a-zA-Z0-9._\/-]+\z/, 
    message: "must be in the format 'host.com/owner/repo'" 
  }
  
  before_validation :normalize_url
  before_validation :generate_slug

  scope :active, -> { where("(repository ->> 'archived') = ?", 'false') }
  scope :archived, -> { where("(repository ->> 'archived') = ?", 'true') }

  scope :fork, -> { where("(repository ->> 'fork') = ?", 'true') }
  scope :source, -> { where("(repository ->> 'fork') = ?", 'false') }

  scope :language, ->(language) { where("(repository ->> 'language') = ?", language) }
  scope :owner, ->(owner) { where("(repository ->> 'owner') = ?", owner) }
  scope :keyword, ->(keyword) { where("keywords @> ARRAY[?]::varchar[]", keyword) }
  scope :with_repository, -> { where.not(repository: nil) }

  scope :with_packages, -> { where('packages_count > 0') }
  scope :without_packages, -> { where(packages_count: 0) }

  scope :order_by_stars, -> { order(Arel.sql("(repository ->> 'stargazers_count')::int desc nulls last")) }

  scope :between, ->(start_date, end_date) { where('projects.created_at > ?', start_date).where('projects.created_at < ?', end_date) }

  def self.purl_without_version(purl)
    Purl.parse(purl.to_s).with(version: nil).to_s
  end

  def self.sync_least_recently_synced
    Project.where(last_synced_at: nil).or(Project.where("last_synced_at < ?", 1.day.ago)).order('last_synced_at asc nulls first').limit(1000).each do |project|
      project.sync_async
    end
  end

  def self.sync_all
    Project.all.each do |project|
      project.sync_async
    end
  end

  def to_s
    display_name
  end

  def repository_url
    repo_url = github_pages_to_repo_url(url)
    return repo_url if repo_url.present?
    url
  end

  def display_name
    url.gsub(/https?:\/\//, '').gsub(/www\./, '').gsub(/\/$/, '')
  end

  def to_param
    slug
  end

  def self.find_by_slug(slug_param)
    find_by(slug: slug_param.to_s.downcase)
  end

  def stars
    return unless repository.present?
    repository['stargazers_count']
  end

  def forks
    return unless repository.present?
    repository['forks_count']
  end

  def watchers
    return unless repository.present?
    repository['subscribers_count']
  end

  def github_pages_to_repo_url(github_pages_url)
    match = github_pages_url.chomp('/').match(/https?:\/\/(.+)\.github\.io\/(.+)/)
    return nil unless match
  
    username = match[1]
    repo_name = match[2]
  
    "https://github.com/#{username}/#{repo_name}"
  end

  def first_created
    return unless repository.present?
    Time.parse(repository['created_at'])
  end

  def sync
    return if sync_status == 'syncing'
    
    sync_started_at = Time.current
    update_columns(sync_status: 'syncing', updated_at: sync_started_at)
    
    begin
      # Broadcast initial sync start
      safe_broadcast_sync_update
      
      # Core sync steps with individual error handling
      sync_step("URL check") { check_url }
      sync_step("Repository fetch") { fetch_repository }
      safe_broadcast_sync_update  # After repository fetch
      
      # Limit packages in test environment to avoid excessive API calls  
      max_pages = Rails.application.config.x.pagination_limits&.dig(:packages) || 100
      sync_step("Packages fetch") { fetch_packages(max_pages: max_pages) }
      safe_broadcast_sync_update  # After packages fetch
      
      if repository && uninteresting_fork?
        Rails.logger.info "Skipping detailed sync for uninteresting fork: #{repository['full_name']}"
      else
        sync_step("README fetch") { fetch_readme }
        sync_step("Tags sync") { sync_tags }
        safe_broadcast_sync_update  # After tags sync
        
        sync_step("Advisories sync") { sync_advisories }
        sync_step("Issues sync") { sync_issues }
        sync_step("Dependabot issues sync") { sync_dependabot_issues }  # Sync Dependabot security issues for GitHub repos
        safe_broadcast_sync_update  # After issues sync
        
        sync_step("Commits sync") { sync_commits }
        safe_broadcast_sync_update  # After commits sync
        
        sync_step("Dependencies fetch") { fetch_dependencies }
        sync_step("Dependency collections update") { update_sourced_dependency_collections }  # Update any collections that use this project as source
        safe_broadcast_sync_update  # After dependencies fetch
        
        sync_step("Collective fetch") { fetch_collective }
        sync_step("GitHub sponsors fetch") { fetch_github_sponsors }
      end
      
      return if destroyed?
      
      # Final completion update
      completion_time = Time.current
      update_columns(
        last_synced_at: completion_time, 
        sync_status: 'completed',
        updated_at: completion_time
      )
      
      safe_broadcast_sync_update  # Final completion broadcast
      sync_step("Ping services") { ping }
      sync_step("Notify collections") { notify_collections_of_sync }
      
      Rails.logger.info "Successfully synced project #{id} in #{(completion_time - sync_started_at).round(2)} seconds"
      
    rescue => e
      Rails.logger.error "Fatal error syncing project #{id}: #{e.class.name} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n") if Rails.env.development?
      
      unless destroyed?
        update_columns(
          sync_status: 'error',
          updated_at: Time.current
        )
      end
      
      # Don't re-raise in production to prevent worker crashes
      raise e if Rails.env.test? || Rails.env.development?
    end
  end

  def uninteresting_fork?
    return false unless repository.present?
    return false unless repository['fork']
    return false unless packages_count.zero?
    return false if repository['archived']
    return false if repository['stargazers_count'] > 10
    true
  end

  def sync_async
    job_id = SyncProjectWorker.perform_async(id)
    update_columns(sync_job_id: job_id) if job_id
    job_id
  end
  
  def job_exists?
    return false if sync_job_id.blank?
    
    # Check if job exists in any Sidekiq queue/set
    Sidekiq::Queue.new.any? { |job| job.jid == sync_job_id } ||
    Sidekiq::ScheduledSet.new.any? { |job| job.jid == sync_job_id } ||
    Sidekiq::RetrySet.new.any? { |job| job.jid == sync_job_id } ||
    Sidekiq::Workers.new.any? { |_process_id, _thread_id, work| work['payload']['jid'] == sync_job_id }
  rescue => e
    Rails.logger.error "Error checking if job exists for project #{id}: #{e.message}"
    false
  end

  def ready?
    return true if sync_status == 'completed'
    return false if sync_status == 'error' || sync_status == 'syncing'
    last_synced_at.present? && last_synced_at > 1.hour.ago
  end

  def never_synced?
    last_synced_at.nil?
  end

  def sync_stuck?
    sync_status == 'syncing' && updated_at < 30.minutes.ago
  end

  def sync_progress
    total_steps = 6
    completed_steps = 0
    completed_steps += 1 if repository.present?
    completed_steps += 1 if packages_last_synced_at.present?
    completed_steps += 1 if issues_last_synced_at.present?
    completed_steps += 1 if commits_last_synced_at.present?
    completed_steps += 1 if tags_last_synced_at.present?
    completed_steps += 1 if dependencies_last_synced_at.present?
    
    {
      total: total_steps,
      completed: completed_steps,
      percentage: (completed_steps.to_f / total_steps * 100).round
    }
  end

  def broadcast_sync_progress
    begin
      data = {
        type: 'progress_update',
        progress: sync_progress,
        ready: ready?
      }
      
      Rails.logger.info "Broadcasting progress update for project #{id}: #{data}"
      
      ProjectSyncChannel.broadcast_to(self, data)
    rescue => e
      Rails.logger.error "Error broadcasting progress update for project #{id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end

  def broadcast_sync_update
    begin
      html_content = ApplicationController.render(
        partial: 'projects/sync_status',
        locals: { project: self }
      )
      
      data = {
        type: 'status_update',
        ready: ready?,
        progress: sync_progress,
        html: html_content
      }
      
      Rails.logger.info "Broadcasting sync update for project #{id}: #{data.except(:html)}"
      
      ProjectSyncChannel.broadcast_to(self, data)
    rescue => e
      Rails.logger.error "Error broadcasting sync update for project #{id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Fallback broadcast without HTML
      fallback_data = {
        type: 'status_update',
        ready: ready?,
        progress: sync_progress
      }
      
      Rails.logger.info "Fallback broadcasting sync update for project #{id}: #{fallback_data}"
      ProjectSyncChannel.broadcast_to(self, fallback_data)
    end
  end

  def test_broadcast
    Rails.logger.info "Sending test broadcast for project #{id}"
    ProjectSyncChannel.broadcast_to(
      self,
      {
        type: 'test',
        message: 'Test broadcast from project',
        timestamp: Time.current.iso8601
      }
    )
  end

  def check_url
    url.chomp!('/')
    conn = Faraday.new(url: url) do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end

    response = conn.get
    return unless response.success?

    update!(url: response.env.url.to_s) 
    # TODO avoid duplicates
  rescue ActiveRecord::RecordInvalid => e
    puts "Duplicate url #{url}"
    puts e.class
    destroy
  rescue
    puts "Error checking url for #{url}"
  end

  def ping
    ping_urls.each do |url|
      ecosystems_api_request(url) rescue nil
    end
  end

  def ping_urls
    ([repos_ping_url] + [issues_ping_url] + [commits_ping_url] + packages_ping_urls).compact.uniq
  end

  def repos_ping_url
    return unless repository.present?
    "https://repos.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}/ping"
  end

  def issues_ping_url
    return unless repository.present?
    "https://issues.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}/ping?priority=true"
  end

  def commits_ping_url
    return unless repository.present?
    "https://commits.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}/ping"
  end

  def packages_ping_urls
    return [] if packages_count.zero?
    packages.map do |package|
      "https://packages.ecosyste.ms/api/v1/registries/#{package.registry_name}/packages/#{package.name}/ping"
    end
  end

  def packages_url(page: 1)
    "https://packages.ecosyste.ms/api/v1/packages/lookup?page=#{page}&repository_url=#{repository_url}"
  end
  
  def description
    return unless repository.present?
    repository["description"]
  end

  def repos_api_url
    "https://repos.ecosyste.ms/api/v1/repositories/lookup?url=#{repository_url}"
  end

  def repos_url
    return unless repository.present?
    "https://repos.ecosyste.ms/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}"
  end

  def fetch_repository
    response = ecosystems_api_request(repos_api_url)
    return unless response&.success?
    
    repo_data = JSON.parse(response.body)
    self.repository = repo_data
    self.keywords = combined_keywords
    
    unless self.save
      Rails.logger.error "Error saving repository data for #{repository_url}: #{self.errors.full_messages.join(', ')}"
      return false
    end
    
    true
  rescue => e
    Rails.logger.error "Error fetching repository for #{repository_url}: #{e.message}"
    false
  end

  def combined_keywords
    keywords = []
    keywords += repository["topics"] if repository.present? && repository["topics"]
    keywords += packages.map(&:keywords).compact.flatten unless packages_count.zero?
    keywords.uniq.reject(&:blank?)
  end
  
  def timeline_url
    return unless repository.present?
    return unless repository["host"]["name"] == "GitHub"

    "https://timeline.ecosyste.ms/api/v1/events/#{repository['full_name']}/summary"
  end

  def language
    return unless repository.present?
    repository['language']
  end

  def language_with_default
    language.presence || 'Unknown'
  end

  def owner_name
    return unless repository.present?
    repository['owner']
  end

  def owner
    return unless repository.present?
    repository['owner']
  end

  def name
    return unless repository.present?
    repository['full_name'].split('/').last
  end

  def avatar_url
    return unless repository.present?
    repository['icon_url']
  end

  def repository_license
    return nil unless repository.present?
    repository['license'] || repository.dig('metadata', 'files', 'license')
  end

  def security_documentation_files
    return {} unless repository&.dig('metadata', 'files').present?
    
    repository['metadata']['files'].select do |k, v|
      v.present? && (k.downcase.include?('security') || k.downcase.include?('threat'))
    end
  end

  def has_security_documentation?
    security_documentation_files.any?
  end

  def has_repository_metadata_files?
    repository&.dig('metadata', 'files').present?
  end

  def licenses
    (packages_licenses + [repository_license]).compact.uniq
  end

  def open_source_license?
    licenses.any?
  end

  def no_license?
    !open_source_license?
  end

  def dependent_packages_count
    return 0 if packages_count.zero?
    packages.select{|p| p.dependent_packages_count }.map{|p| p.dependent_packages_count || 0 }.sum
  end

  def dependent_repos_count
    return 0 if packages_count.zero?
    packages.select{|p| p.dependent_repos_count }.map{|p| p.dependent_repos_count || 0 }.sum
  end

  def archived?
    return false unless repository.present?
    repository['archived']
  end

  def active?
    return false if archived?
  end

  def fork?
    return false unless repository.present?
    repository['fork']
  end

  def download_url
    return unless repository.present?
    repository['download_url']
  end

  def archive_url(path)
    return unless download_url.present?
    "https://archives.ecosyste.ms/api/v1/archives/contents?url=#{download_url}&path=#{path}"
  end

  def blob_url(path)
    return unless repository.present?
    "#{repository['html_url']}/blob/#{repository['default_branch']}/#{path}"
  end 

  def raw_url(path)
    return unless repository.present?
    "#{repository['html_url']}/raw/#{repository['default_branch']}/#{path}"
  end 

  def no_funding?
    funding_links.empty?
  end

  def funding_links
    (repo_funding_links + package_funding_links + owner_funding_links + readme_funding_links).uniq
  end

  def package_funding_links
    return [] if packages_count.zero?
    packages.map(&:funding).compact.flatten.map do |f|
      case f
      when Hash
        f['url']
      when String
        f
      else
        nil
      end
    end.compact
  end

  def owner_funding_links
    return [] unless owner
    return [] if owner["metadata"].blank?
    return [] unless owner["metadata"]['has_sponsors_listing']
    ["https://github.com/sponsors/#{owner['login']}"]
  end

  def repo_funding_links
    return [] if repository.blank? || repository['metadata'].blank? ||  repository['metadata']["funding"].blank?
    return [] if repository['metadata']["funding"].is_a?(String)
    repository['metadata']["funding"].map do |key,v|
      next if v.blank?
      case key
      when "github"
        Array(v).map{|username| "https://github.com/sponsors/#{username}" }
      when "tidelift"
        "https://tidelift.com/funding/github/#{v}"
      when "community_bridge"
        "https://funding.communitybridge.org/projects/#{v}"
      when "issuehunt"
        "https://issuehunt.io/r/#{v}"
      when "open_collective"
        "https://opencollective.com/#{v}"
      when "ko_fi"
        "https://ko-fi.com/#{v}"
      when "liberapay"
        "https://liberapay.com/#{v}"
      when "custom"
        v
      when "otechie"
        "https://otechie.com/#{v}"
      when "patreon"
        "https://patreon.com/#{v}"
      when "polar"
        "https://polar.sh/#{v}"
      when 'buy_me_a_coffee'
        "https://buymeacoffee.com/#{v}"
      when 'thanks_dev'
        "https://thanks.dev/#{v}"
      else
        v
      end
    end.flatten.compact
  end

  def issues_api_url
    "https://issues.ecosyste.ms/api/v1/repositories/lookup?url=#{repository_url}&priority=true"
  end

  def sync_issues
    return unless repository.present?
    
    response_data = fetch_json_with_retry(issues_api_url)
    return unless response_data
    
    issues_list_url = response_data['issues_url']
    
    # Find the oldest issue we haven't synced yet by looking at created_at timestamps
    # Start from the oldest unsynced issue to avoid re-processing the same records
    latest_issue_created_at = issues.order(:created_at).last&.created_at
    
    # Build URL with parameters to get oldest issues first
    url_params = []
    url_params << "sort=created_at"
    url_params << "order=asc"  # ascending to get oldest first
    
    if latest_issue_created_at.present?
      # Use created_after to start from where we left off
      url_params << "created_after=#{latest_issue_created_at.iso8601}"
    end
    
    # Add parameters to URL
    separator = issues_list_url.include?('?') ? '&' : '?'
    paginated_url = "#{issues_list_url}#{separator}#{url_params.join('&')}"
    
    # Limit pages in test environment to avoid excessive HTTP requests
    max_pages = Rails.application.config.x.pagination_limits&.dig(:issues) || 50
    per_page = Rails.application.config.x.per_page_limits&.dig(:issues) || 100
    issues_data = fetch_paginated_data(paginated_url, per_page: per_page, max_pages: max_pages)
    
    # Process issues if we have any
    unless issues_data.empty?
      # Get valid Issue attributes to filter out unknown attributes
      valid_attributes = Issue.attribute_names.to_set
      
      issue_records = issues_data.map do |issue|
        # Filter to only include valid attributes
        issue_attributes = issue.select { |key, _| valid_attributes.include?(key.to_s) }
        issue_attributes['project_id'] = id
        issue_attributes
      end
      
      # Remove duplicates from the current batch to avoid conflicts
      unique_issue_records = issue_records.uniq { |record| [record['project_id'], record['number']] }
      
      # Get existing issue numbers for this project to avoid duplicates
      existing_numbers = issues.where(number: unique_issue_records.map { |r| r['number'] }).pluck(:number).to_set
      
      # Split into new and existing records  
      new_records = unique_issue_records.reject { |record| existing_numbers.include?(record['number']) }
      update_records = unique_issue_records.select { |record| existing_numbers.include?(record['number']) }
      
      # Bulk insert new records (this will trigger counter_culture callbacks)
      Issue.insert_all(new_records) if new_records.any?
      
      # Update existing records if needed
      if update_records.any?
        update_records.each do |record|
          issues.where(number: record['number']).update_all(
            record.except('project_id', 'created_at', 'number')
          )
        end
      end
    end
    
    # Always set the timestamp when we successfully get a response
    self.issues_last_synced_at = Time.now
    self.save
    
  rescue => e
    Rails.logger.error "Error fetching issues for #{repository_url}: #{e.message}"
  end

  def sync_dependabot_issues
    dependabot_url = dependabot_api_url
    return unless dependabot_url
    
    response = Faraday.new(url: dependabot_url) do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end.get
    
    return unless response.success?
    
    dependabot_issues = JSON.parse(response.body)
    return if dependabot_issues.empty?
    
    # Get valid Issue attributes to filter out unknown attributes
    valid_attributes = Issue.attribute_names.to_set
    
    issue_records = dependabot_issues.map do |issue|
      # Filter to only include valid attributes
      issue_attributes = issue.select { |key, _| valid_attributes.include?(key.to_s) }
      issue_attributes['project_id'] = id
      issue_attributes
    end
    
    # Remove duplicates from the current batch to avoid conflicts
    unique_issue_records = issue_records.uniq { |record| [record['project_id'], record['uuid']] }
    
    # Get existing issue UUIDs for this project to avoid duplicates
    existing_uuids = issues.where(uuid: unique_issue_records.map { |r| r['uuid'] }).pluck(:uuid).to_set
    
    # Split into new and existing records  
    new_records = unique_issue_records.reject { |record| existing_uuids.include?(record['uuid']) }
    update_records = unique_issue_records.select { |record| existing_uuids.include?(record['uuid']) }
    
    # Bulk insert new records
    Issue.insert_all(new_records) if new_records.any?
    
    # Update existing records if needed
    if update_records.any?
      update_records.each do |record|
        issues.where(uuid: record['uuid']).update_all(
          record.except('project_id', 'created_at', 'uuid')
        )
      end
    end
    
  rescue => e
    Rails.logger.error "Error fetching Dependabot issues for #{repository_url}: #{e.message}"
  end

  def github_repository?
    repository.present? && repository['host']['name'] == 'GitHub'
  end

  def commits_api_url
    "https://commits.ecosyste.ms/api/v1/repositories/lookup?url=#{repository_url}"
  end

  def sync_commits
    return unless repository.present?
    
    response_data = fetch_json_with_retry(commits_api_url)
    return unless response_data
    
    # Find the latest commit timestamp we have to start from where we left off
    # Use timestamp instead of created_at since commits are ordered by their actual commit time
    latest_commit_timestamp = commits.order(:timestamp).last&.timestamp
    
    # Build URL with parameters to get oldest commits first
    url_params = []
    url_params << "sort=timestamp"
    url_params << "order=asc"  # ascending to get oldest first
    
    if latest_commit_timestamp.present?
      # Use since parameter to start from where we left off
      url_params << "since=#{latest_commit_timestamp.iso8601}"
    end
    
    # Add parameters to URL
    commits_list_url = response_data['commits_url']
    separator = commits_list_url.include?('?') ? '&' : '?'
    paginated_url = "#{commits_list_url}#{separator}#{url_params.join('&')}"
    
    # Limit pages in test environment to avoid excessive HTTP requests  
    max_pages = Rails.application.config.x.pagination_limits&.dig(:commits) || 50
    per_page = Rails.application.config.x.per_page_limits&.dig(:commits) || 1000
    commits_data = fetch_paginated_data(paginated_url, per_page: per_page, max_pages: max_pages)
    
    # Process commits if we have any
    unless commits_data.empty?
    
    commit_records = commits_data.map do |commit|
      commit_attributes = commit.except('stats', 'html_url')
      commit_attributes['additions'] = commit['stats']&.dig('additions')
      commit_attributes['deletions'] = commit['stats']&.dig('deletions') 
      commit_attributes['files_changed'] = commit['stats']&.dig('files_changed')
      commit_attributes['project_id'] = id
      commit_attributes['created_at'] = Time.current
      commit_attributes['updated_at'] = Time.current
      commit_attributes
    end
    
    # Remove duplicates from the current batch to avoid conflicts
    unique_commit_records = commit_records.uniq { |record| [record['project_id'], record['sha']] }
    
    # Get existing commit shas for this project to avoid duplicates
    existing_shas = commits.where(sha: unique_commit_records.map { |r| r['sha'] }).pluck(:sha).to_set
    
    # Split into new and existing records
    new_records = unique_commit_records.reject { |record| existing_shas.include?(record['sha']) }
    update_records = unique_commit_records.select { |record| existing_shas.include?(record['sha']) }
    
    # Bulk insert new records
    Commit.insert_all(new_records) if new_records.any?
    
    # Update existing records if needed
    if update_records.any?
      update_records.each do |record|
        commits.where(sha: record['sha']).update_all(
          message: record['message'],
          timestamp: record['timestamp'],
          merge: record['merge'],
          author: record['author'],
          committer: record['committer'],
          additions: record['additions'],
          deletions: record['deletions'],
          files_changed: record['files_changed'],
          updated_at: record['updated_at']
        )
      end
    end
    end
    
    # Always set the timestamp when we successfully get a response
    self.commits_last_synced_at = Time.now
    self.save

  rescue => e
    Rails.logger.error "Error fetching commits for #{repository_url}: #{e.message}"
  end

  def tags_api_url(page: 1, per_page: 100)
    "https://repos.ecosyste.ms/api/v1/hosts/#{repository['host']['name']}/repositories/#{repository['full_name']}/tags?page=#{page}&per_page=#{per_page}"
  end

  def sync_tags
    return unless repository.present?

    # Fetch all tags first using existing paginated method
    base_url = tags_api_url(page: 1, per_page: 100)
    max_pages = Rails.application.config.x.pagination_limits&.dig(:tags) || 50
    per_page = Rails.application.config.x.per_page_limits&.dig(:tags) || 100
    
    # Collect all tags from all pages
    all_tags = []
    page = 1
    loop do
      conn = Faraday.new(url: tags_api_url(page: page, per_page: per_page)) do |faraday|
        faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
        faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
      end
      response = conn.get
      return unless response.success?

      tags_json = JSON.parse(response.body)
      break if tags_json.empty?
      
      all_tags.concat(tags_json)
      page += 1
      break if page > max_pages
    end
    
    # Use bulk insert for performance
    return if all_tags.empty?
    
    tag_records = all_tags.map do |tag|
      tag_attributes = tag.slice('sha', 'kind', 'published_at', 'html_url')
      tag_attributes['name'] = tag['name']
      tag_attributes['project_id'] = id
      tag_attributes['created_at'] = Time.current
      tag_attributes['updated_at'] = Time.current
      tag_attributes
    end
    
    # Remove duplicates from the current batch to avoid conflicts
    unique_tag_records = tag_records.uniq { |record| [record['project_id'], record['name']] }
    
    # Get existing tag names for this project to avoid duplicates
    existing_names = tags.where(name: unique_tag_records.map { |r| r['name'] }).pluck(:name).to_set
    
    # Split into new and existing records
    new_records = unique_tag_records.reject { |record| existing_names.include?(record['name']) }
    update_records = unique_tag_records.select { |record| existing_names.include?(record['name']) }
    
    # Bulk insert new records
    Tag.insert_all(new_records) if new_records.any?
    
    # Update existing records if needed
    if update_records.any?
      update_records.each do |record|
        tags.where(name: record['name']).update_all(
          record.except('project_id', 'created_at', 'name')
        )
      end
    end
    
    self.tags_last_synced_at = Time.now
    self.save
  rescue => e
    Rails.logger.error "Error fetching tags for #{repository_url}: #{e.message}"
  end

  def sync_advisories
    return unless repository.present?

    # Limit pages in test environment to avoid excessive HTTP requests
    max_pages = Rails.application.config.x.pagination_limits&.dig(:advisories) || 50
    per_page = Rails.application.config.x.per_page_limits&.dig(:advisories) || 100
    page = 1
    loop do
      conn = Faraday.new(url: advisories_api_url(page: page, per_page: per_page)) do |faraday|
        faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
        faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
      end
      response = conn.get
      return unless response.success?

      advisories_json = JSON.parse(response.body)
      break if advisories_json.empty? # Stop if there are no more advisories

      advisories_json.each do |advisory|
        a = advisories.find_or_create_by(uuid: advisory['uuid'])
        advisory_attributes = advisory
        a.assign_attributes(advisory_attributes)
        a.save(touch: false)
      end

      page += 1
      break if page > max_pages # Stop if there are too many advisories
    end
  rescue => e
    Rails.logger.error "Error fetching advisories for #{repository_url}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  def advisories_api_url(page: 1, per_page: 100)
    "https://advisories.ecosyste.ms/api/v1/advisories?page=#{page}&per_page=#{per_page}&repository_url=#{repository_url}"
  end

  def dependabot_api_url
    return unless repository.present? && github_repository?
    return unless repository['full_name'].present?
    
    # Use the full_name from repository metadata (e.g., "sparklemotion/nokogiri")
    full_name = repository['full_name']
    owner, repo_name = full_name.split('/', 2)
    return unless owner.present? && repo_name.present?
    
    encoded_owner = URI.encode_www_form_component(owner)
    encoded_repo = URI.encode_www_form_component(repo_name)
    "https://dependabot.ecosyste.ms/api/v1/hosts/GitHub/repositories/#{encoded_owner}%2F#{encoded_repo}/issues"
  end

  def last_activity_at
    return unless repository.present?
    return unless repository['pushed_at'].present?
    Time.parse(repository['pushed_at'])
    # TODO: Use issues updated_at
  end

  def last_commit_at
    return unless commits.present?
    commits.order('timestamp desc').first.timestamp
  end

  def latest_tag
    return unless tags.present?
    tags.order('published_at desc').first
  end

  def latest_tag_name
    return unless tags.present?
    latest_tag.name
  end

  def latest_tag_published_at
    return unless tags.present?
    latest_tag.try(:published_at)
  end

  def packages_homepage_urls
    packages.map(&:homepage_url).compact.uniq
  end

  def homepage_url
    return unless repository.present?
    return unless repository['homepage'].present?
    ([repository['homepage']] + packages_homepage_urls).compact.uniq
  end

  def documentation_urls
    packages.map(&:documentation_url).compact.uniq
  end

  def registry_urls
    packages.map(&:registry_url).compact.uniq
  end

  def links
    [
      url,
      homepage_url,
      documentation_urls,
      registry_urls,
      funding_links
  ].flatten.compact.uniq.sort
  end

  def essential_links
    [
      url,
      homepage_url,
      documentation_urls,
      funding_links
    ].flatten.compact.uniq.sort
  end

  def fetch_packages(max_pages: 10)
    base_url = "https://packages.ecosyste.ms/api/v1/packages/lookup?repository_url=#{repository_url}"
    per_page = Rails.application.config.x.per_page_limits&.dig(:packages) || 100
    packages_data = fetch_paginated_data(base_url, per_page: per_page, max_pages: max_pages)
    
    packages_data.each do |pkg|
      p = packages.find_or_create_by(ecosystem: pkg['ecosystem'], name: pkg['name'])
      p.purl = pkg['purl']
      p.metadata = pkg.except('repo_metadata')
      p.save(touch: false)
    end
    
    self.packages_last_synced_at = Time.now
    self.save
  rescue => e
    Rails.logger.error "Error fetching packages for #{repository_url}: #{e.message}"
  end

  def packages_count
    # TODO use counter cache instead
    packages.count
  end

  def advisories_count
    advisories.count
  end

  def monthly_downloads
    return 0 if packages_count.zero?
    packages.select{|p| p.downloads_period == 'last-month' }.map{|p| p.downloads || 0 }.sum
  end

  def downloads
    return 0 if packages_count.zero?
    packages.map{|p| p.downloads || 0 }.sum
  end

  def dependent_packages
    return 0 if packages_count.zero?
    packages.select{|p| p.dependents }.map{|p| p.dependents || 0 }.sum
  end

  def dependent_repositories
    return 0 if packages_count.zero?
    packages.select{|p| p.dependent_repos_count }.map{|p| p.dependent_repos_count || 0 }.sum
  end

  def dependents
    dependent_packages + dependent_repositories
  end

  def packages_licenses
    return [] if packages_count.zero?
    packages.map{|p| p.licenses }.compact.flatten.uniq
  end

  def purl_kind
    return unless repository.present?
    repository['host']['kind']
  end

  def project_purl
    return unless repository.present?
    PackageURL.new(
      type: purl_kind,
      namespace: owner_name,
      name: name
    ).to_s
  end

  def purls
    return if packages.blank?
    @purls ||= packages.map{|p| Purl.parse(p.purl) }
  end

  def self.find_by_purl(purl)
    package_url(purl.to_s).first
  end

  def readme_file_name
    return unless repository.present?
    return unless repository['metadata'].present?
    return unless repository['metadata']['files'].present?
    repository['metadata']['files']['readme']
  end

  def fetch_readme
    if readme_file_name.blank? || download_url.blank?
      fetch_readme_fallback
    else
      conn = Faraday.new(url: archive_url(readme_file_name)) do |faraday|
        faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
        faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
      end
      response = conn.get
      return unless response.success?
      json = JSON.parse(response.body)

      self.readme = json['contents']
      self.save
    end
  rescue
    puts "Error fetching readme for #{repository_url}"
    fetch_readme_fallback
  end

  def fetch_readme_fallback
    file_name = readme_file_name.presence || 'README.md'
    conn = Faraday.new(url: raw_url(file_name)) do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end

    response = conn.get
    return unless response.success?
    self.readme = response.body
    self.save
  rescue
    puts "Error fetching readme for #{repository_url}"
  end

  def readme_url
    return unless repository.present?
    "#{repository['html_url']}/blob/#{repository['default_branch']}/#{readme_file_name}"
  end

  def readme_urls
    return [] unless readme.present?
    urls = URI.extract(readme.gsub(/[\[\]]/, ' '), ['http', 'https']).uniq
    # remove trailing garbage
    urls.map{|u| u.gsub(/\:$/, '').gsub(/\*$/, '').gsub(/\.$/, '').gsub(/\,$/, '').gsub(/\*$/, '').gsub(/\)$/, '').gsub(/\)$/, '').gsub('&nbsp;','') }
  end

  def funding_domains
    ['opencollective.com', 'ko-fi.com', 'liberapay.com', 'patreon.com', 'otechie.com', 'issuehunt.io', 'thanks.dev',
    'communitybridge.org', 'tidelift.com', 'buymeacoffee.com', 'paypal.com', 'paypal.me','givebutter.com', 'polar.sh']
  end

  def readme_funding_links
    urls = readme_urls.select{|u| funding_domains.any?{|d| u.include?(d) } || u.include?('github.com/sponsors') }.reject{|u| ['.svg', '.png'].include? File.extname(URI.parse(u).path) }
    # remove anchors
    urls = urls.map{|u| u.gsub(/#.*$/, '') }.uniq
    # remove sponsor/9/website from open collective urls
    urls = urls.map{|u| u.gsub(/\/sponsor\/\d+\/website$/, '') }.uniq
  end

  def badges
    Rails.cache.fetch("badges:#{id}", expires_in: 1.month) do
      [
        fork_badge,
        archived_badge,
        package_badge,
        mature_age_badge,
        veteran_age_badge,
        new_age_badge,
        star_popularity_badge,
        download_popularity_badge,
        dependents_popularity_badge,
        high_contributors_badge,
        low_contributors_badge,
        active_badge,
        inactive_badge
      ].compact
    end
  end

  def fork_badge
    return unless fork?
    {
      label: 'Fork',
      class: 'warning'
    }
  end

  def archived_badge
    return unless archived?
    {
      label: 'Archived',
      class: 'danger'
    }
  end

  def package_badge
    return if packages_count.zero?
    {
      label: 'Package',
      class: 'info'
    }
  end

  def mature_age_badge
    return unless first_created.present?
    return unless first_created < 5.year.ago
    return unless first_created > 10.year.ago
    {
      label: 'Mature',
      class: 'success'
    }
  end

  def veteran_age_badge
    return unless first_created.present?
    return unless first_created < 10.year.ago
    {
      label: 'Veteran',
      class: 'primary'
    }
  end

  def new_age_badge
    return unless first_created.present?
    return unless first_created > 6.month.ago
    {
      label: 'Emerging',
      class: 'secondary'
    }
  end

  def star_popularity_badge
    if stars.present? && stars > 1000
      {
        label: 'Popular: Stars',
        class: 'success'
      }
    end
  end

  def download_popularity_badge
    if downloads > 10000
      {
        label: 'Popular: Downloads',
        class: 'success'
      }
    end
  end

  def dependents_popularity_badge
    if dependents > 100
      {
        label: 'Popular: Dependents',
        class: 'success'
      }
    end
  end

  def high_contributors_badge
    if issues.group(:user).count.count > 30
      {
        label: 'Many Contributors',
        class: 'success'
      }
    end
  end

  def low_contributors_badge
    if issues.group(:user).count.count < 3
      {
        label: 'Few contributors',
        class: 'warning'
      }
    end
  end

  def active_badge
    if (last_activity_at && last_activity_at > 1.month.ago) || issues.where('created_at > ?', 1.month.ago).count > 0 || issues.where('closed_at > ?', 1.month.ago).count > 0
      {
        label: 'Active',
        class: 'info'
      }
    end
  end

  def inactive_badge
    if (last_activity_at && last_activity_at  < 2.year.ago) || (issues.where('closed_at > ?',  1.year.ago).count == 0 && (last_activity_at && last_activity_at  < 1.year.ago)) 
      {
        label: 'Inactive',
        class: 'danger'
      }
    end
  end

  def maintainers(range: 30)
    
  end

  def fetch_dependencies
    return unless repository.present?
    conn = Faraday.new(url: repository['manifests_url']) do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end
    response = conn.get
    return unless response.success?
    self.dependencies = JSON.parse(response.body)
    
    # Calculate and cache dependency counts
    self.direct_dependencies_count = direct_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }.length
    self.development_dependencies_count = development_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }.length
    self.transitive_dependencies_count = transitive_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }.length
    
    self.dependencies_last_synced_at = Time.now
    self.save
  rescue => e
    Rails.logger.error "Error fetching dependencies for #{url}: #{e.message}"
  end

  def all_dependencies
    return [] if dependencies.blank?
    dependencies.map{|m| m['dependencies'] }.flatten.compact
  end

  def direct_dependencies
    return [] if dependencies.blank?
    all_dependencies.select{|d| d['direct'] == true }
  end

  def development_dependencies
    return [] if dependencies.blank?
    all_dependencies.select{|d| ['development', 'dev', 'test', 'build'].include? d['kind']  }
  end

  def transitive_dependencies
    return [] if dependencies.blank?
    all_dependencies.select{|d| d['direct'] == false }
  end

  def total_dependencies_count
    direct_dependencies_count + development_dependencies_count + transitive_dependencies_count
  end

  def advisories_count
    advisories.count
  end

  def fetch_collective
    return unless funding_links.any?{|f| f.include?('opencollective.com') }
    return if collective_id.present?
    
    slug = funding_links.find{|f| f.include?('opencollective.com') }.split('/').last

    c = Collective.find_or_create_by(slug: slug) 

    if c.persisted?
      c.sync_async 
      self.collective_id = c.id
      save
    end
  end

  def collective_url
    collective&.html_url
  end

  def fetch_github_sponsors
    return unless funding_links.any?{|f| f.include?('github.com/sponsors') }
    
    slug = funding_links.find{|f| f.include?('github.com/sponsors') }.split('/').last

    url = "https://sponsors.ecosyste.ms/api/v1/accounts/#{slug}"

    conn = Faraday.new(url: url) do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end

    response = conn.get
    return unless response.success?
      
    json = JSON.parse(response.body)

    update_column(:github_sponsors, json) if json.present?
  rescue
    puts "Error fetching github sponsors for #{repository_url}"
  end

  def dependency_collection_for_user(user)
    sourced_collections.where(user: user).first
  end

  def create_or_update_collection_from_dependencies(user, name: nil, include_development: true)
    existing_collection = dependency_collection_for_user(user)
    
    if existing_collection
      update_dependency_collection(existing_collection, include_development: include_development)
    else
      create_collection_from_dependencies(user, name: name, include_development: include_development)
    end
  end

  def update_sourced_dependency_collections
    # Update all collections that use this project as their source
    sourced_collections.find_each do |collection|
      begin
        Rails.logger.info "Auto-updating dependency collection #{collection.id} (#{collection.name}) from project #{id}"
        update_dependency_collection(collection)
      rescue => e
        Rails.logger.error "Error auto-updating dependency collection #{collection.id}: #{e.message}"
        # Don't let collection update errors break project sync
      end
    end
  end

  def update_dependency_collection(collection, include_development: true)
    return nil if dependencies.blank? || all_dependencies.empty?
    
    # Update the dependency file with current dependencies
    deps_to_process = if include_development
      all_dependencies
    else
      # Only include direct runtime dependencies (exclude development)
      direct_dependencies.reject { |dep| ['development', 'dev', 'test', 'build'].include?(dep['kind']) }
    end
    
    # Convert dependencies to PURLs
    purls = deps_to_process.map do |dep|
      next nil unless dep['package_name'] && dep['ecosystem']
      
      # Use the Package class method to convert ecosystem types to PURL types
      ecosystem_type = Package.convert_ecosystem_to_purl_type(dep['ecosystem'])
      
      "pkg:#{ecosystem_type}/#{dep['package_name']}"
    end.compact
    
    # Create updated SBOM format for the dependency file
    sbom = {
      "SPDXID" => "SPDXRef-DOCUMENT",
      "spdxVersion" => "SPDX-2.3",
      "creationInfo" => {
        "created" => Time.current.iso8601,
        "creators" => ["Tool: dashboards.ecosyste.ms"]
      },
      "name" => collection.name,
      "packages" => purls.map.with_index do |purl, index|
        {
          "SPDXID" => "SPDXRef-Package-#{index + 1}",
          "name" => purl,
          "externalRefs" => [
            {
              "referenceCategory" => "PACKAGE-MANAGER",
              "referenceType" => "purl",
              "referenceLocator" => purl
            }
          ]
        }
      end
    }
    
    collection.dependency_file = sbom.to_json
    
    if collection.save
      collection.import_projects_async
      collection
    else
      nil
    end
  end

  def create_collection_from_dependencies(user, name: nil, include_development: true)
    return nil if dependencies.blank? || all_dependencies.empty?
    
    collection_name = name || "#{display_name} Dependencies"
    
    collection = Collection.new(
      name: collection_name,
      description: "Dependencies of #{display_name}",
      user: user,
      visibility: 'public',
      source_project: self
    )
    
    # Create dependency file JSON from project's dependencies
    deps_to_process = if include_development
      all_dependencies
    else
      # Only include direct runtime dependencies (exclude development)
      direct_dependencies.reject { |dep| ['development', 'dev', 'test', 'build'].include?(dep['kind']) }
    end
    
    # Convert dependencies to PURLs
    purls = deps_to_process.map do |dep|
      next nil unless dep['package_name'] && dep['ecosystem']
      
      # Use the Package class method to convert ecosystem types to PURL types
      ecosystem_type = Package.convert_ecosystem_to_purl_type(dep['ecosystem'])
      
      "pkg:#{ecosystem_type}/#{dep['package_name']}"
    end.compact
    
    # Create SBOM format for the dependency file
    sbom = {
      "SPDXID" => "SPDXRef-DOCUMENT",
      "spdxVersion" => "SPDX-2.3",
      "creationInfo" => {
        "created" => Time.current.iso8601,
        "creators" => ["Tool: dashboards.ecosyste.ms"]
      },
      "name" => collection_name,
      "packages" => purls.map.with_index do |purl, index|
        {
          "SPDXID" => "SPDXRef-Package-#{index + 1}",
          "name" => purl,
          "externalRefs" => [
            {
              "referenceCategory" => "PACKAGE-MANAGER",
              "referenceType" => "purl",
              "referenceLocator" => purl
            }
          ]
        }
      end
    }
    
    collection.dependency_file = sbom.to_json
    
    if collection.save
      collection.import_projects_async
      collection
    else
      nil
    end
  end

  def current_github_sponsors_count
    return 0 unless github_sponsors.present?
    github_sponsors['active_sponsors_count'] || 0
  end

  def total_github_sponsors_count
    return 0 unless github_sponsors.present?
    github_sponsors['sponsors_count'] || 0
  end

  def past_github_sponsors_count
    total_github_sponsors_count - current_github_sponsors_count
  end

  def github_minimum_sponsorship_amount
    return 1 unless github_sponsors.present?
    github_sponsors['minimum_sponsorship_amount'] || 1
  end

  def github_sponsors_url
    return unless github_sponsors.present?
    github_sponsors['sponsors_url']
  end

  def find_or_create_owner_collection(user)
    return nil unless repository.present? && repository['owner_url'].present?
    
    # Fetch owner metadata from the API
    response = ecosystems_api_request(repository['owner_url'])
    return nil unless response&.success?
    
    owner_data = JSON.parse(response.body)
    return nil unless owner_data['html_url'].present?
    
    collection_name = owner_data['login'] || owner_data['name']
    
    Collection.find_or_create_by(
      github_organization_url: owner_data['html_url'],
      user: user
    ) do |collection|
      collection.name = collection_name
      collection.description = "Collection of repositories for #{collection_name}"
      collection.visibility = 'public'
    end
  rescue => e
    Rails.logger.error "Error creating owner collection: #{e.message}"
    nil
  end

  def find_existing_owner_collection
    return nil unless repository.present? && repository['owner_url'].present?
    
    # Fetch owner metadata from the API
    response = ecosystems_api_request(repository['owner_url'])
    return nil unless response&.success?
    
    owner_data = JSON.parse(response.body)
    return nil unless owner_data['html_url'].present?
    
    # Look for existing public collection
    Collection.visible.find_by(github_organization_url: owner_data['html_url'])
  rescue => e
    Rails.logger.error "Error finding existing owner collection: #{e.message}"
    nil
  end

  def other_funding_links
    funding_links
      .reject{|f| f.include?('github.com/sponsors') || f.include?('opencollective.com') }
      .map { |link| normalize_funding_link(link) }
      .uniq
      .reject { |link| reject_invalid_funding_link?(link) }
  end

  def normalize_url
    return if url.blank?
    
    # Remove trailing slashes from the URL
    self.url = url.strip.gsub(/\/+$/, '')
  end

  def generate_slug
    return if url.blank?

    begin
      url_to_parse = url.strip

      # Add scheme if missing (common for user input like "github.com/owner/repo")
      unless url_to_parse.match?(/\A[a-z][a-z0-9+.-]*:/i)
        url_to_parse = "https://#{url_to_parse}"
      end

      # Parse URL safely
      uri = URI.parse(url_to_parse)
      return unless uri.host && uri.path

      # Build safe slug from parsed components
      host = uri.host.downcase.gsub(/^www\./, '')
      path = uri.path.gsub(/^\//, '').gsub(/\/$/, '')

      # Only allow valid characters
      host = host.gsub(/[^a-zA-Z0-9._-]/, '')
      path = path.gsub(/[^a-zA-Z0-9._\/-]/, '')

      # Ensure we have both host and path
      return if host.blank? || path.blank?

      candidate_slug = "#{host}/#{path}".downcase

      # Final validation - must match expected format
      if candidate_slug.match?(/\A[a-zA-Z0-9._-]+\/[a-zA-Z0-9._\/-]+\z/)
        self.slug = candidate_slug
      else
        Rails.logger.warn "Could not generate valid slug for URL: #{url}"
      end

    rescue URI::InvalidURIError => e
      Rails.logger.error "Invalid URL format for project: #{url} - #{e.message}"
    end
  end

  def reject_invalid_funding_link?(link)
    uri = URI.parse(link)
    
    case uri.host
    when 'tidelift.com'
      return reject_generic_tidelift_link?(link)
    when 'img.buymeacoffee.com'
      # Reject image/button API links
      return true
    when 'blog.tidelift.com'
      # Reject blog links
      return true
    when /^(www\.)?ko-fi\.com$/
      # Reject ko-fi links that are just random IDs (like O5O86SNP4)
      path_parts = uri.path.split('/').reject(&:empty?)
      return path_parts.any? && path_parts.first.match?(/^[A-Z0-9]+$/) && path_parts.first.length > 6
    end
    
    false
  end

  def reject_generic_tidelift_link?(link)
    uri = URI.parse(link)
    return false unless uri.host == 'tidelift.com'
    
    # Remove query params to check the clean path
    clean_path = uri.path
    
    # Reject generic paths like /funding/github
    return true if clean_path == '/funding/github' || clean_path == '/funding/github/'
    
    # Check if the link contains the project name (only if we have a project name)
    return false if name.blank?
    
    project_name_variants = [
      name,
      name&.downcase,
      name&.gsub(/[-_]/, ''),
      name&.gsub(/[-_]/, '')&.downcase
    ].compact.uniq
    
    project_name_variants.none? { |variant| clean_path.include?(variant) }
  end

  def normalize_funding_link(link)
    uri = URI.parse(link)
    uri.query = nil
    
    # Remove www. subdomain for consistency
    if uri.host&.start_with?('www.')
      uri.host = uri.host[4..-1]
    end
    
    # Normalize specific funding platforms
    case uri.host
    when 'tidelift.com'
      # Keep only the base tidelift.com/funding or tidelift.com/subscription path
      if uri.path.start_with?('/funding/')
        uri.path = uri.path.split('/')[0..2].join('/')
      elsif uri.path.start_with?('/subscription/')
        uri.path = uri.path.split('/')[0..3].join('/')
      end
    when 'liberapay.com'
      # Keep only the username part, remove /donate
      path_parts = uri.path.split('/')
      if path_parts.last == 'donate' && path_parts.length > 2
        uri.path = path_parts[0..-2].join('/')
      end
    end
    
    uri.to_s
  end

  def notify_collections_of_sync
    # Notify ALL collections this project belongs to, not just ones currently syncing
    # This ensures all users viewing any collection containing this project see updates
    collections.each do |collection|
      collection.broadcast_sync_progress
    end
  end

  def sync_step(step_name)
    Rails.logger.debug "Starting sync step: #{step_name} for project #{id}"
    start_time = Time.current
    
    begin
      yield
      duration = (Time.current - start_time).round(2)
      Rails.logger.debug "Completed sync step: #{step_name} for project #{id} in #{duration}s"
    rescue => e
      duration = (Time.current - start_time).round(2)
      Rails.logger.warn "Failed sync step: #{step_name} for project #{id} after #{duration}s - #{e.class.name}: #{e.message}"
      # Continue with sync even if individual steps fail
    end
  end

  def safe_broadcast_sync_update
    broadcast_sync_update
    # Also notify collections of the update so the syncing page stays updated
    notify_collections_of_sync
  rescue => e
    Rails.logger.warn "Failed to broadcast sync update for project #{id}: #{e.message}"
    # Continue sync even if broadcast fails
  end

  def fetch_json_with_retry(url, retries: 3)
    conn = Faraday.new(url: url) do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end
    
    response = conn.get
    return nil unless response.success?
    
    JSON.parse(response.body)
  rescue => e
    retries -= 1
    retry if retries > 0
    Rails.logger.error "Failed to fetch JSON from #{url}: #{e.message}"
    nil
  end

  def fetch_paginated_data(url, per_page: 100, max_pages: 10)
    data = []
    page = 1
    
    loop do
      page_url = "#{url}#{url.include?('?') ? '&' : '?'}per_page=#{per_page}&page=#{page}"
      conn = Faraday.new(url: page_url) do |faraday|
        faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
        faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
      end
      
      response = conn.get
      break unless response.success?
      
      page_data = JSON.parse(response.body)
      break if page_data.empty?
      
      data.concat(page_data)
      page += 1
      break if page > max_pages
    end
    
    data
  rescue => e
    Rails.logger.error "Failed to fetch paginated data from #{url}: #{e.message}"
    []
  end
end
