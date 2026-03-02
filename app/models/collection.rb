class Collection < ApplicationRecord
  include EcosystemsApiClient

  def self.sortable_columns
    {
      'collections.updated_at' => 'collections.updated_at',
      'collections.created_at' => 'collections.created_at',
      'name' => 'name',
    }
  end

  has_many :collection_projects, dependent: :destroy
  has_many :active_collection_projects, -> { active }, class_name: 'CollectionProject'
  has_many :projects, through: :active_collection_projects

  has_many :issues, through: :projects
  has_many :commits, through: :projects
  has_many :tags, through: :projects
  has_many :packages, through: :projects
  has_many :advisories, through: :projects

  belongs_to :user
  belongs_to :source_project, class_name: 'Project', optional: true

  scope :visible, -> { where(visibility: 'public') }
  scope :sync_eligible, -> { where.not(import_status: 'importing') }


  before_validation :set_name_from_source
  before_validation :generate_slug
  after_create :update_slug_if_needed
  validate :at_least_one_import_source, on: :create
  validate :valid_dependency_file_format
  
  validates :github_organization_url, format: { with: %r{\Ahttps://github\.com/[^/]+/?\z}, message: "must be a valid GitHub organization URL" }, allow_blank: true
  validates :collective_url, format: { with: %r{\Ahttps://opencollective\.com/[^/]+/?\z}, message: "must be a valid Open Collective URL" }, allow_blank: true
  validates :github_repo_url, format: { with: %r{\Ahttps://github\.com/[^/]+/[^/]+/?\z}, message: "must be a valid GitHub repository URL" }, allow_blank: true
  validates :slug, presence: true, uniqueness: { case_sensitive: false }


  def set_name_from_source
    return if name.present?

    self.name =
      github_organization_url&.sub(%r{\Ahttps://}, '') ||
      collective_url&.sub(%r{\Ahttps://}, '') ||
      github_repo_url&.sub(%r{\Ahttps://}, '') ||
      (dependency_file.presence && "SBOM from upload")
  end

  def at_least_one_import_source
    if github_organization_url.blank? &&
      collective_url.blank? &&
      github_repo_url.blank? &&
      dependency_file.blank?
      errors.add(:base, "You must provide a source: GitHub org, Open Collective URL, repo URL, or dependency file.")
    end
  end

  def valid_dependency_file_format
    return if dependency_file.blank?
    
    begin
      JSON.parse(dependency_file)
    rescue JSON::ParserError => e
      errors.add(:dependency_file, "must be a valid JSON SBOM file")
    end
  end

  def to_param
    slug
  end
  
  def self.find_by_slug(slug_param)
    find_by(slug: slug_param.to_s.downcase)
  end

  def import_projects_sync
    import_projects_with_mode
  end

  def import_projects_async
    ImportCollectionWorker.perform_async(id)
  end

  def sync_projects
    Rails.logger.info "Starting sync for collection: #{name} (ID: #{id})"
    
    # Re-import to get any new projects
    import_projects_sync
    
    # Queue ALL current projects (existing + newly imported) that need syncing
    queued_count = 0
    projects.each do |project|
      # Skip if already syncing
      next if project.sync_status == 'syncing'
      
      # Queue if never synced or needs refresh
      if project.last_synced_at.blank?
        job_id = SyncProjectWorker.perform_async(project.id)
        project.update_columns(sync_job_id: job_id) if job_id
        queued_count += 1
        Rails.logger.info "Queued project #{project.id} (#{project.url}) for initial sync with job_id: #{job_id}"
      end
    end
    
    # Update status to syncing and start monitoring (if not already done by import)
    if sync_status != 'syncing'
      update_with_broadcast(sync_status: 'syncing')
      job_id = CheckCollectionSyncStatusWorker.perform_async(id)
      update_columns(sync_job_id: job_id) if job_id
    end
    
    Rails.logger.info "Queued #{queued_count} of #{projects.count} projects for syncing in collection: #{name}"
  end

  def import_projects_with_mode
    update_with_broadcast(import_status: 'importing', sync_status: 'pending', last_error_message: nil, last_error_backtrace: nil, last_error_at: nil)
    
    if respond_to?(:github_organization_url) && github_organization_url.present?
      import_from_github_org
    elsif respond_to?(:collective_url) && collective_url.present?
      import_from_opencollective
    elsif respond_to?(:github_repo_url) && github_repo_url.present?
      import_from_repo
    elsif respond_to?(:dependency_file) && dependency_file.present?
      import_from_dependency_file
    end
    
    update_with_broadcast(import_status: 'completed', sync_status: 'syncing')
    
    # Start background job to monitor individual project sync completion
    CheckCollectionSyncStatusWorker.perform_async(id)
  rescue StandardError => e
    Rails.logger.error "Error importing projects for collection #{id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    
    update_with_broadcast(
      import_status: 'error',
      sync_status: 'error',
      last_error_message: e.message,
      last_error_backtrace: e.backtrace.join("\n"),
      last_error_at: Time.current
    )
  end

  def import_from_github_org
    return if github_organization_url.blank?
    uri = URI.parse(github_organization_url)
    org_name = uri.path.split("/")[1]
    import_github_org(org_name)
  end

  def import_from_opencollective
    return if collective_url.blank?
    uri = URI.parse(collective_url)
    org_name = uri.path.split("/")[1]
    
    oc_api_url = "https://opencollective.ecosyste.ms/api/v1/collectives/#{org_name}/projects"
    resp = Faraday.get(oc_api_url, nil, {'User-Agent' => 'dashboards.ecosyste.ms'})
    if resp.status == 200
      data = JSON.parse(resp.body)
      urls = data.map { |p| p['url'] }.uniq.reject(&:blank?)
      urls.each do |url|
        next if url.blank?
        
        begin
          project = Project.find_or_create_by(url: url)
          next unless project&.persisted?
          
          CollectionProject.add_project_to_collection(self, project)
          
          # Queue for sync if never synced
          if project.last_synced_at.blank?
            job_id = SyncProjectWorker.perform_async(project.id)
        project.update_columns(sync_job_id: job_id) if job_id
            Rails.logger.info "Queued project #{project.id} (#{url}) for initial sync during import with job_id: #{job_id}"
          end
          
          broadcast_sync_progress
        rescue => e
          Rails.logger.error "Error creating project for URL #{url}: #{e.message}"
          next
        end
      end
    else
      update_with_broadcast(import_status: 'error', sync_status: 'error')
    end
  end

  def import_from_repo
    repos_url = "https://repos.ecosyste.ms/api/v1/repositories/lookup?url=#{CGI.escape(github_repo_url)}"
    
    conn = Faraday.new do |f|
      f.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      f.headers['X-Source'] = 'dashboards.ecosyste.ms'
      f.headers['X-API-Key'] = ENV['ECOSYSTEMS_API_KEY'] if ENV['ECOSYSTEMS_API_KEY']
      f.options.timeout = 30  # 30 seconds timeout
      f.options.open_timeout = 10  # 10 seconds to establish connection
      f.request :retry, max: 3, interval: 2, backoff_factor: 2,
                retry_statuses: [429, 500, 502, 503, 504],
                methods: [:get]
      f.adapter Faraday.default_adapter
    end
    
    begin
      resp = conn.get(repos_url)
    rescue Faraday::Error => e
      Rails.logger.error "Error fetching repo lookup for #{github_repo_url}: #{e.message}"
      update_with_broadcast(import_status: 'error', sync_status: 'error')
      return
    end
    if resp.status == 200
      data = JSON.parse(resp.body)
      sbom_url = data['sbom_url']
      if sbom_url.present?
        sbom = conn.get(sbom_url)
        if sbom.status == 200
          json = JSON.parse(sbom.body)
          purls = Sbom.extract_purls_from_json(json)
          urls = Sbom.fetch_project_urls_from_purls(purls)
          urls.each do |url|
            next if url.blank?
            
            begin
              project = Project.find_or_create_by(url: url)
              next unless project&.persisted?
              
              CollectionProject.add_project_to_collection(self, project)
              
              # Queue individual sync job for each project if it needs syncing
              if project.last_synced_at.blank?
                job_id = SyncProjectWorker.perform_async(project.id)
        project.update_columns(sync_job_id: job_id) if job_id
              end
              
              broadcast_sync_progress
            rescue => e
              Rails.logger.error "Error creating project for URL #{url}: #{e.message}"
              next
            end
          end
        else
          update_with_broadcast(import_status: 'error', sync_status: 'error')
        end
      end
    end
  end

  def import_from_dependency_file
    return if dependency_file.blank?
    
    begin
      # Create SBOM record to handle processing
      Sbom.create!(raw: dependency_file)
      
      # Parse the SBOM JSON
      json = JSON.parse(dependency_file)
      
      # Extract PURLs from the SBOM using the SBOM class method
      purls = Sbom.extract_purls_from_json(json)
      
      # Convert PURLs to project URLs using the SBOM class method
      urls = Sbom.fetch_project_urls_from_purls(purls)
      
      # Create projects for each URL
      urls.each do |url|
        next if url.blank?
        
        begin
          project = Project.find_or_create_by(url: url)
          next unless project&.persisted?
          
          CollectionProject.add_project_to_collection(self, project)
          
          # Queue for sync if never synced
          if project.last_synced_at.blank?
            job_id = SyncProjectWorker.perform_async(project.id)
        project.update_columns(sync_job_id: job_id) if job_id
            Rails.logger.info "Queued project #{project.id} (#{url}) for initial sync during import with job_id: #{job_id}"
          end
          
          broadcast_sync_progress
        rescue => e
          Rails.logger.error "Error creating project for URL #{url}: #{e.message}"
          next
        end
      end
      
      Rails.logger.info "Successfully imported #{urls.length} projects from SBOM dependency file"
      
    rescue JSON::ParserError => e
      Rails.logger.error "Error parsing SBOM JSON: #{e.message}"
      update_with_broadcast(import_status: 'error', sync_status: 'error', last_error_message: "Invalid SBOM file format: #{e.message}")
      raise e
    rescue => e
      Rails.logger.error "Error importing from dependency file: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      update_with_broadcast(import_status: 'error', sync_status: 'error', last_error_message: e.message, last_error_backtrace: e.backtrace.join("\n"))
      raise e
    end
  end

  def self.sync_least_recently_synced(limit = 10)
    collections_to_sync = sync_eligible
      .order(Arel.sql('last_synced_at ASC NULLS FIRST'))
      .limit(limit)

    collections_to_sync.each do |collection|
      Rails.logger.info "Queuing collection sync for: #{collection.name} (ID: #{collection.id})"
      SyncCollectionWorker.perform_async(collection.id)
    end

    Rails.logger.info "Queued #{collections_to_sync.count} collections for syncing"
  end

  def self.import_github_org(org_name, user:)
    collection = Collection.find_or_create_by(name: org_name, user: user) do |collection|
      collection.name = org_name
      collection.description = "Collection of repositories for #{org_name}"
      collection.user = user
      collection.github_organization_url = "https://github.com/#{org_name}"
    end
    collection.import_github_org(org_name)
    collection
  end

  def import_github_org(org_name)
    page = 1
    projects_created = 0
    projects_queued = 0
    
    loop do
      conn = Faraday.new do |f|
        f.headers['User-Agent'] = 'dashboards.ecosyste.ms'
        f.headers['X-Source'] = 'dashboards.ecosyste.ms'
        f.headers['X-API-Key'] = ENV['ECOSYSTEMS_API_KEY'] if ENV['ECOSYSTEMS_API_KEY']
        f.options.timeout = 30  # 30 seconds timeout
        f.options.open_timeout = 10  # 10 seconds to establish connection
        f.request :retry, max: 3, interval: 2, backoff_factor: 2,
                  retry_statuses: [429, 500, 502, 503, 504],
                  methods: [:get]
        f.adapter Faraday.default_adapter
      end
      
      begin
        per_page = Rails.application.config.x.per_page_limits&.dig(:repositories) || 100
        resp = conn.get("https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/#{org_name}/repositories?per_page=#{per_page}&page=#{page}")
        break unless resp.status == 200
      rescue Faraday::Error => e
        Rails.logger.error "Error fetching GitHub org repos for #{org_name}, page #{page}: #{e.message}"
        break
      end

      data = JSON.parse(resp.body)
      break if data.empty?

      urls = data.map{|p| p['html_url'] }.uniq.reject(&:blank?)
      urls.each do |url|
        next if url.blank?
        
        begin
          project = Project.find_or_create_by(url: url)
          next unless project&.persisted?
          
          CollectionProject.add_project_to_collection(self, project)
          projects_created += 1
          
          # Queue for sync if never synced
          if project.last_synced_at.blank?
            job_id = SyncProjectWorker.perform_async(project.id)
        project.update_columns(sync_job_id: job_id) if job_id
            projects_queued += 1
            Rails.logger.info "Queued project #{project.id} (#{url}) for initial sync during import with job_id: #{job_id}"
          end
          
          broadcast_sync_progress
        rescue => e
          Rails.logger.error "Error creating project for URL #{url}: #{e.message}"
          next
        end
      end

      page += 1
    end
    
    Rails.logger.info "GitHub org import for #{org_name} completed: #{projects_created} projects found, #{projects_queued} queued for sync"
  end

  def to_s
    name
  end

  def syncing?
    import_status == 'importing' || sync_status == 'syncing'
  end

  def ready?
    import_status == 'completed' && sync_status == 'ready'
  end

  def sync_stuck?
    sync_status == 'syncing' && updated_at < 30.minutes.ago
  end

  def check_and_update_sync_status
    # Check if all projects have been synced
    total_projects = projects.count
    synced_projects = projects.where.not(last_synced_at: nil).count
    
    if total_projects == 0
      # No projects found during import - mark as ready
      update_with_broadcast(sync_status: 'ready', last_synced_at: Time.current)
    elsif synced_projects == total_projects
      # All projects have been synced - recalculate dependency counts and mark as ready
      recalculate_dependency_counts!
      update_with_broadcast(sync_status: 'ready', last_synced_at: Time.current)
    else
      # Still syncing projects - broadcast progress update
      broadcast_sync_progress
    end
  end

  def projects_sync_progress
    total = projects.count
    synced = projects.where.not(last_synced_at: nil).count
    { total: total, synced: synced }
  end

  def currently_syncing_projects
    projects.where(sync_status: 'syncing').limit(10)
  end

  def pending_sync_projects
    projects.where(last_synced_at: nil).where.not(sync_status: 'syncing').limit(5)
  end

  def recently_synced_projects
    projects.where.not(last_synced_at: nil).order(last_synced_at: :desc).limit(5)
  end


  def job_exists?(job_id)
    return false if job_id.blank?
    
    # Check if job exists in any Sidekiq queue/set
    Sidekiq::Queue.new.any? { |job| job.jid == job_id } ||
    Sidekiq::ScheduledSet.new.any? { |job| job.jid == job_id } ||
    Sidekiq::RetrySet.new.any? { |job| job.jid == job_id } ||
    Sidekiq::Workers.new.any? { |_process_id, _thread_id, work| work['payload']['jid'] == job_id }
  rescue => e
    Rails.logger.error "Error checking if job exists: #{e.message}"
    false
  end
  
  def has_pending_but_nothing_queued?
    # Collection needs recovery if:
    # 1. Import is completed
    # 2. There are unsynced projects
    # 3. No projects are currently syncing
    # 4. No valid jobs exist for these projects
    
    Rails.logger.info "Checking if collection #{id} has pending but nothing queued..."
    Rails.logger.info "  import_status: #{import_status}, sync_status: #{sync_status}"
    
    unless import_status == 'completed'
      Rails.logger.info "  -> false (import not completed)"
      return false
    end
    
    if sync_status == 'ready' || sync_status == 'error'
      Rails.logger.info "  -> false (sync_status is #{sync_status})"
      return false
    end
    
    pending_projects = projects.where(last_synced_at: nil)
    Rails.logger.info "  Found #{pending_projects.count} pending projects"
    
    if pending_projects.empty?
      Rails.logger.info "  -> false (no pending projects)"
      return false
    end
    
    # Check if any projects are actively syncing
    syncing_count = projects.where(sync_status: 'syncing').count
    Rails.logger.info "  Projects with sync_status='syncing': #{syncing_count}"
    
    if syncing_count > 0
      Rails.logger.info "  -> false (#{syncing_count} projects actively syncing)"
      return false
    end
    
    # Check if any pending projects have valid jobs using stored job IDs
    jobs_exist = false
    pending_projects.find_each do |project|
      if project.sync_job_id.present? && project.job_exists?
        Rails.logger.info "  Project #{project.id} has valid job #{project.sync_job_id}"
        jobs_exist = true
        break
      end
    end
    
    if jobs_exist
      Rails.logger.info "  -> false (found valid jobs for pending projects)"
      return false
    end
    
    # Also check for jobs we might not have tracked (fallback)
    project_ids = pending_projects.pluck(:id)
    Rails.logger.info "  Double-checking Sidekiq for project IDs: #{project_ids.inspect}"
    
    # In test mode, check the fake queue
    if Rails.env.test? && defined?(Sidekiq::Testing) && Sidekiq::Testing.fake?
      fake_jobs = SyncProjectWorker.jobs.select do |job|
        project_ids.include?(job['args'][0])
      end
      Rails.logger.info "  Jobs in fake queue (test mode): #{fake_jobs.count}"
      result = fake_jobs.empty?
    else
      # In production/development, check real queues
      queued_jobs = Sidekiq::Queue.new.select do |job|
        job.klass == 'SyncProjectWorker' && project_ids.include?(job.args[0])
      end
      Rails.logger.info "  Jobs in main queue: #{queued_jobs.count}"
      
      scheduled_jobs = Sidekiq::ScheduledSet.new.select do |job|
        job.klass == 'SyncProjectWorker' && project_ids.include?(job.args[0])
      end
      Rails.logger.info "  Jobs in scheduled set: #{scheduled_jobs.count}"
      
      retry_jobs = Sidekiq::RetrySet.new.select do |job|
        job.klass == 'SyncProjectWorker' && project_ids.include?(job.args[0])
      end
      Rails.logger.info "  Jobs in retry set: #{retry_jobs.count}"
      
      # If no jobs are queued/scheduled/retrying for our pending projects, we're stuck
      result = queued_jobs.empty? && scheduled_jobs.empty? && retry_jobs.empty?
    end
    Rails.logger.info "  -> #{result} (needs recovery: #{result})"
    result
  end

  def recover_stuck_sync!
    return false unless has_pending_but_nothing_queued?
    
    Rails.logger.info "Recovering stuck sync for collection #{id}: re-enqueueing pending projects"
    
    # Clear old job IDs that are no longer valid
    projects.where.not(sync_job_id: nil).update_all(sync_job_id: nil)
    
    # Queue sync for ALL unsynced projects (not just 10)
    unsynced_projects = projects.where(last_synced_at: nil)
    queued_count = 0
    
    unsynced_projects.find_each do |project|
      # Double-check project isn't already syncing
      next if project.sync_status == 'syncing'
      
      job_id = SyncProjectWorker.perform_async(project.id)
      project.update_columns(sync_job_id: job_id) if job_id
      queued_count += 1
      Rails.logger.info "Re-queued project #{project.id} (#{project.url}) for sync with job_id: #{job_id}"
    end
    
    Rails.logger.info "Recovery complete: queued #{queued_count} projects for collection #{id}"
    
    # Update collection status if needed
    if sync_status != 'syncing'
      update_columns(sync_status: 'syncing', updated_at: Time.current)
    end
    
    # Ensure monitoring job is running
    job_id = CheckCollectionSyncStatusWorker.perform_async(id)
    update_columns(sync_job_id: job_id) if job_id
    
    broadcast_sync_progress
    true
  end

  def avatar_url
    ''
  end


  def last_commit_at
    projects.map(&:last_commit_at).compact.max
  end

  def latest_tag_name
    projects.select{|p| p.latest_tag.present? }.sort_by(&:latest_tag_published_at).last&.latest_tag_name
  end

  def latest_tag_published_at
    projects.map(&:latest_tag_published_at).compact.max
  end

  def links
    projects.map(&:links).flatten.uniq.sort
  end

  def essential_links
    projects.map(&:essential_links).flatten.uniq
  end

  def licenses
    projects.map(&:licenses).flatten.uniq
  end

  def collective
    nil # TODO: Fix this 🐉
  end

  def unique_collective_ids
    projects.where.not(collective_id: nil).distinct.pluck(:collective_id)
  end
  
  def has_github_sponsors?
    projects.where.not(github_sponsors: nil).exists?
  end
  
  def total_github_sponsors_count
    projects.where.not(github_sponsors: nil).sum { |p| p.current_github_sponsors_count }
  end
  
  def github_sponsors_projects_count
    projects.where.not(github_sponsors: nil).count
  end

  def watchers
    projects.map(&:watchers).compact.sum
  end

  def forks
    projects.map(&:forks).compact.sum
  end

  def stars
    projects.map(&:stars).compact.sum
  end

  def direct_dependencies
    @direct_dependencies ||= projects.map(&:direct_dependencies).flatten.uniq { |dep| dep['package_name'] || dep['name'] }
  end

  def development_dependencies
    @development_dependencies ||= projects.map(&:development_dependencies).flatten.uniq { |dep| dep['package_name'] || dep['name'] }
  end

  def transitive_dependencies
    @transitive_dependencies ||= projects.map(&:transitive_dependencies).flatten.uniq { |dep| dep['package_name'] || dep['name'] }
  end

  def dependent_packages_count
    projects.map(&:dependent_packages_count).compact.sum
  end

  def dependent_repos_count
    projects.map(&:dependent_repos_count).compact.sum
  end

  def downloads
    projects.map(&:downloads).compact.sum
  end

  def calculate_and_cache_dependency_counts
    # Calculate unique dependency counts by deduplicating across projects
    direct_count = direct_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }.length
    development_count = development_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }.length
    transitive_count = transitive_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }.length
    
    # Update the cached counts
    update_columns(
      direct_dependencies_count: direct_count,
      development_dependencies_count: development_count,
      transitive_dependencies_count: transitive_count
    )
    
    {
      direct: direct_count,
      development: development_count,
      transitive: transitive_count
    }
  end

  def recalculate_dependency_counts!
    calculate_and_cache_dependency_counts
  end

  def total_dependencies_count
    direct_dependencies_count + development_dependencies_count + transitive_dependencies_count
  end

  def advisories_count
    advisories.count
  end

  def broadcast_sync_progress
    begin
      # Always include HTML for consistent updates
      html_content = ApplicationController.render(
        partial: 'collections/sync_status',
        locals: { collection: self }
      )
      
      data = {
        type: 'progress_update',
        progress: projects_sync_progress,
        sync_status: sync_status,
        import_status: import_status,
        html: html_content
      }
      
      Rails.logger.info "Broadcasting progress update for collection #{id}: #{data.except(:html)}"
      
      CollectionSyncChannel.broadcast_to(self, data)
    rescue => e
      Rails.logger.error "Error broadcasting progress update for collection #{id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Fallback without HTML
      fallback_data = {
        type: 'progress_update',
        progress: projects_sync_progress,
        sync_status: sync_status
      }
      
      CollectionSyncChannel.broadcast_to(self, fallback_data)
    end
  end

  def test_broadcast
    Rails.logger.info "Sending test broadcast for collection #{id}"
    CollectionSyncChannel.broadcast_to(
      self,
      {
        type: 'test',
        message: 'Test broadcast from collection',
        timestamp: Time.current.iso8601
      }
    )
  end

  def update_with_broadcast(attributes)
    update(attributes)
    broadcast_sync_update
  end

  def broadcast_sync_update
    begin
      html_content = ApplicationController.render(
        partial: 'collections/sync_status',
        locals: { collection: self }
      )
      
      data = {
        type: 'status_update',
        import_status: import_status,
        sync_status: sync_status,
        progress: projects_sync_progress,
        error_message: last_error_message,
        html: html_content
      }
      
      Rails.logger.info "Broadcasting sync update for collection #{id}: #{data.except(:html)}"
      
      CollectionSyncChannel.broadcast_to(self, data)
    rescue => e
      Rails.logger.error "Error broadcasting sync update for collection #{id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Fallback broadcast without HTML
      fallback_data = {
        type: 'status_update',
        import_status: import_status,
        sync_status: sync_status,
        progress: projects_sync_progress,
        error_message: last_error_message
      }
      
      CollectionSyncChannel.broadcast_to(self, fallback_data)
    end
  end
  
  def generate_slug
    return if slug.present?
    
    if github_organization_url.present?
      # Owner collection: github.com/owner format
      generate_owner_slug_from_github_url
    elsif collective_url.present?
      # Open Collective: opencollective.com/owner format  
      generate_owner_slug_from_collective_url
    else
      # For other types, we'll use UUID after creation
      self.slug = 'temp-slug-' + SecureRandom.hex(8)
    end
  end
  
  def update_slug_if_needed
    if slug&.start_with?('temp-slug-')
      update_column(:slug, uuid)
    end
  end
  
  def generate_owner_slug_from_github_url
    begin
      uri = URI.parse(github_organization_url.strip)
      
      if uri.host && uri.path
        # Extract owner name from path (e.g. "/octobox" -> "octobox")
        path = uri.path.gsub(/^\//, '').gsub(/\/$/, '')
        
        if path.present?
          # Create slug in format: github.com/owner
          candidate_slug = "github.com/#{path}".downcase
          
          # Validate format
          if candidate_slug.match?(/\Agithub\.com\/[a-zA-Z0-9._-]+\z/)
            self.slug = candidate_slug
            return
          end
        end
      end
      
      # Fallback for invalid URLs
      Rails.logger.warn "Could not generate valid owner slug for GitHub URL: #{github_organization_url}"
      self.slug = 'temp-slug-' + SecureRandom.hex(8)
      
    rescue URI::InvalidURIError => e
      Rails.logger.error "Invalid GitHub organization URL format: #{github_organization_url} - #{e.message}"
      self.slug = 'temp-slug-' + SecureRandom.hex(8)
    end
  end
  
  def generate_owner_slug_from_collective_url
    begin
      uri = URI.parse(collective_url.strip)
      
      if uri.host && uri.path
        # Extract collective name from path (e.g. "/babel" -> "babel")  
        path = uri.path.gsub(/^\//, '').gsub(/\/$/, '')
        
        if path.present?
          # Create slug in format: opencollective.com/collective
          candidate_slug = "opencollective.com/#{path}".downcase
          
          # Validate format
          if candidate_slug.match?(/\Aopencollective\.com\/[a-zA-Z0-9._-]+\z/)
            self.slug = candidate_slug
            return
          end
        end
      end
      
      # Fallback for invalid URLs
      Rails.logger.warn "Could not generate valid owner slug for Open Collective URL: #{collective_url}"
      self.slug = 'temp-slug-' + SecureRandom.hex(8)
      
    rescue URI::InvalidURIError => e
      Rails.logger.error "Invalid Open Collective URL format: #{collective_url} - #{e.message}"
      self.slug = 'temp-slug-' + SecureRandom.hex(8)
    end
  end
end

