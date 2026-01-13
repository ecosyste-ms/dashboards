class Collective < ApplicationRecord
  include Charts
  include Stats
  include EcosystemsApiClient

  validates :slug, presence: true

  has_many :projects
  has_many :projects_with_repository, -> { with_repository }, class_name: 'Project'

  has_many :issues, through: :projects
  has_many :commits, through: :projects
  has_many :tags, through: :projects
  has_many :packages, through: :projects
  has_many :advisories, through: :projects

  has_many :transactions, dependent: :destroy

  scope :with_transactions, -> { where.not(transactions_count: 0) }

  scope :with_projects, -> { where.not(projects_count: 0) }
  
  scope :with_owner, -> { where.not(owner: nil) }
  scope :with_org_owner, -> { with_owner.where("owner ->> 'kind' = 'organization'") }
  scope :with_user_owner, -> { with_owner.where("owner ->> 'kind' = 'user'") }

  scope :inactive, -> { where("last_project_activity_at < ?", 1.year.ago) }
  scope :archived, -> { where(archived: true) }

  scope :no_funding, -> { where(no_funding: true) }
  scope :no_license, -> { where(no_license: true) }

  scope :account_type, ->(account_type) { where(account_type: account_type) }
  scope :collectives, -> { account_type('COLLECTIVE') }

  scope :host, ->(host) { where(host: host) }
  scope :opensource, -> { host('opensource') }

  before_save :set_last_project_activity_at
  before_save :set_archived
  before_save :set_no_funding
  before_save :set_no_license

  def self.sync_least_recently_synced
    Collective.where(last_synced_at: nil).or(Collective.where("last_synced_at < ?", 1.day.ago)).order('last_synced_at asc nulls first').limit(20).each_with_index do |collective, index|
      collective.sync_async(delay: index * 30.seconds)
    end
  end

  def self.sync_least_recently_synced_osc
    Collective.collectives.where("last_synced_at < ?", 1.day.ago).order('last_synced_at asc nulls first').limit(20).each_with_index do |collective, index|
      collective.sync_async(delay: index * 30.seconds)
    end
  end

  def to_s
    name.presence || slug
  end

  def to_param
    slug
  end

  def html_url
    "https://opencollective.com/#{slug}"
  end

  def icon_url(size: 40)
    "https://images.opencollective.com/#{slug}/logo/#{size}.png"
  end

  def self.tags
    pluck(Arel.sql("unnest(tags)")).flatten.reject(&:blank?).group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
  end

  def project_topics
    projects.pluck(Arel.sql("repository -> 'topics'")).flatten.reject(&:blank?).group_by(&:itself).transform_values(&:count).sort_by{|k,v| v}.reverse
  end

  def set_last_project_activity_at
    self.last_project_activity_at = projects_with_repository.select{|p| p.last_activity_at.present? }.sort_by(&:last_activity_at).last.try(:last_activity_at)
  end

  def set_archived
    if projects_with_repository.length == 0
      self.archived = false
    else
      self.archived = projects_with_repository.all?{|p| p.archived? }
    end
  end

  def inactive?
    return false if last_project_activity_at.nil?
    last_project_activity_at < 1.year.ago
  end

  def org_owner?
    return false if owner.nil?
    owner['kind'] == 'organization'
  end

  def sync_async(delay: nil)
    if delay
      SyncCollectiveWorker.perform_in(delay, id)
    else
      SyncCollectiveWorker.perform_async(id)
    end
  end

  def fetch_from_open_collective_graphql
    query = <<~GRAPHQL
      query {
        account(slug: "#{slug}") {
          id
          name
          description
          slug
          website
          githubHandle
          twitterHandle
          currency
          type
          createdAt
          updatedAt
          socialLinks {
            type
            url
          }
        }
      }
    GRAPHQL

    response = Faraday.post("https://opencollective.com/api/graphql/v2?personalToken=#{ENV['OPEN_COLLECTIVE_API_KEY']}", { query: query }.to_json, { 'Content-Type' => 'application/json' })
    JSON.parse(response.body)['data']['account']
  rescue
      nil
  end

  def fetch_collective_from_open_collective_graphql
    query = <<~GRAPHQL
      query {
        collective(slug: "#{slug}") {
          id
          name
          description
          slug
          website
          githubHandle
          twitterHandle
          currency
          type
          createdAt
          updatedAt
          socialLinks {
            type
            url
          }
          host {
            slug
          }
        }
      }
    GRAPHQL

    response = Faraday.post("https://opencollective.com/api/graphql/v2?personalToken=#{ENV['OPEN_COLLECTIVE_API_KEY']}", { query: query }.to_json, { 'Content-Type' => 'application/json' })
    JSON.parse(response.body)['data']['collective']
  rescue
      nil
  end

  def map_from_open_collective_graphql
    data = fetch_from_open_collective_graphql
    return if data.nil?
    
    hash = {
      uuid: data['id'],
      name: data['name'],
      description: data['description'],
      website: data['website'],
      github: data['githubHandle'],
      twitter: data['twitterHandle'],
      currency: data['currency'],
      # tags: data['tags'],
      repository_url: data['repositoryUrl'],
      social_links: data['socialLinks'],
      account_type: data['type'],
      collective_created_at: data['createdAt'],
      collective_updated_at: data['updatedAt'],
      last_synced_at: Time.now
    }

    if data['type'] == 'COLLECTIVE'
      sleep 0.5 # Rate limit between API calls
      collective_data = fetch_collective_from_open_collective_graphql
      hash[:host] = collective_data.dig('host', 'slug')
    end
    
    hash
  end

  def fetch_account_details
    updated_attrs = map_from_open_collective_graphql
    update(updated_attrs) if updated_attrs.present?
  end

  def sync
    puts "Syncing #{slug}"
    fetch_account_details
    sleep 0.5 # Rate limit between API calls
    sync_transactions
    if account_type == 'COLLECTIVE' && !duplicate?
      sync_owner
      ping_owner
    end
  rescue => e
    puts "Error syncing #{slug}"
    puts e.message
    puts e.backtrace
  end

  def duplicate?
    !!slug.match(/\w+-\d+\z/) && Collective.where(slug: slug.gsub(/-\d+\z/, '')).exists?
  end

  def ping_owner_url
    return unless project_url.present?
    return unless project_org?
    "https://repos.ecosyste.ms/api/v1/hosts/#{project_host}/owners/#{project_owner}/ping"
  end

  def ping_owner
    Faraday.get(ping_owner_url, nil, {'User-Agent' => 'dashboards.ecosyste.ms'}) rescue nil
  end

  def fetch_owner
    return unless project_owner.present?
    
    conn = Faraday.new(url: "https://repos.ecosyste.ms") do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-API-Key'] = ENV['ECOSYSTEMS_API_KEY'] if ENV['ECOSYSTEMS_API_KEY']
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end

    resp = conn.get("/api/v1/hosts/#{project_host}/owners/#{project_owner}")
    return unless resp.status == 200
    JSON.parse(resp.body)
  rescue => e
    puts "Error fetching owner for #{slug}: #{e.message}"
    nil
  end

  def sync_owner
    owner = fetch_owner
    return unless owner.present?
    update(owner: owner) 
  end

  def website
    return read_attribute(:website) if read_attribute(:website).present?
    (social_links || {}).select{|x| ['WEBSITE'].include? x['type']}.first.try(:[], 'url') || ''
  end

  def project_url
    return repository_url if repository_url.present?
    social_link =(social_links || {}).select{|x| ['GITHUB', 'GITLAB', 'GIT'].include? x['type']}.first.try(:[], 'url')
    
    # check if website is a github repo
    return website if website.match(/github.com\/(.*)/i)

    # check if website is a github pages site
    return github_pages_to_repo_url(website) if website.match(/github.io/i)
    
    # check if website is a gitlab repo
    return website if website.match(/gitlab.com\/(.*)/i)

    # validate social link (path should start with a letter)
    # TODO sr.ht slugs start with ~
    if social_link.present?
      uri = URI.parse(social_link)
      social_link = nil unless uri.path.match(/\/[a-zA-Z]/)
    end

    return social_link if social_link.present?

    return "https://github.com/#{github}" if github.present?

    nil
  end

  def github_pages_to_repo_url(github_pages_url)
    match = github_pages_url.chomp('/').match(/https?:\/\/(.+)\.github\.io(\/(.+))?/)
    return nil unless match

    username = match[1]
    repo_name = match[3]

    "https://github.com/#{username}#{repo_name ? "/#{repo_name}" : ""}"
  end

  def project_org?
    return false if project_url.nil?
    case URI.parse(project_url).host
    when 'github.com'
      project_url.match(/github.com\/(.*)/)[1].split('/').count == 1
    when 'gitlab.com'
      project_url.match(/gitlab.com\/(.*)/)[1].split('/').count == 1
    when 'codeberg.org'
      project_url.match(/codeberg.org\/(.*)/)[1].split('/').count == 1
    else
      false
    end
  end

  def project_host
    return unless project_url.present?
    host = URI.parse(project_url).host
    host = 'GitHub' if host == 'github.com'
    host
  end

  def project_owner
    return unless project_url.present?
    return projects.first.owner_name if projects.any? && projects.first.owner_name.present?
    URI.parse(project_url).path.split('/').reject(&:blank?).first
  end

  def load_projects
    return if project_url.nil?
    if project_org?
      load_org_projects
    else
      project = projects.find_or_create_by(url: project_url)
      project.sync_async if project.last_synced_at.nil?
      # load_org_projects
    end
  rescue
    puts "Error loading projects for #{slug}"
  end

  def load_org_projects
    page = 1
    loop do
      per_page = Rails.application.config.x.per_page_limits&.dig(:repositories) || 100
      resp = Faraday.get("https://repos.ecosyste.ms/api/v1/hosts/#{project_host}/owners/#{project_owner}/repositories?per_page=#{per_page}&page=#{page}", nil, {'User-Agent' => 'dashboards.ecosyste.ms'})
      break unless resp.status == 200

      data = JSON.parse(resp.body)
      break if data.empty? # Stop if there are no more repositories

      urls = data.map{|p| p['html_url'] }.uniq.reject(&:blank?)
      urls.each do |url|
        puts url
        project = projects.find_or_create_by(url: url)
        project.sync_async unless project.last_synced_at.present?
      end

      page += 1
    end
  end

  def self.discover
    first_page = load_osc_projects
    total_count = first_page['data']['account']['memberOf']['totalCount']
    puts "Total count: #{total_count}"
    offset = 0
    job_index = 0
    while offset < total_count
      puts "Loading page #{offset}"
      page = load_osc_projects(offset: offset)
      page['data']['account']['memberOf']['nodes'].each do |node|
        puts "Loading #{node['account']['slug']}"
        collective = Collective.find_or_create_by(slug: node['account']['slug'])
        if collective.last_synced_at.nil?
          collective.sync_async(delay: job_index * 30.seconds)
          job_index += 1
        end
      end
      offset += 100
      sleep 1 # Rate limit between pagination requests
    end
  end

  def self.load_osc_projects(offset: 0)
    graphql_url = "https://opencollective.com/api/graphql/v2?personalToken=#{ENV['OPEN_COLLECTIVE_API_KEY']}"

    query = <<~GRAPHQL
      query ContributionsSection(
        $orderBy: OrderByInput
      ) {
        account(slug: "opensource") {
          memberOf(
            limit: 100
            offset: #{offset}
            role: HOST
            accountType: COLLECTIVE
            orderByRoles: true
            isApproved: true
            isArchived: false
            orderBy: $orderBy
          ) {
            offset
            limit
            totalCount
            nodes {
              id
              since
              account {
                id
                slug
              }
            }
          }
        }
      }
    GRAPHQL

    conn = Faraday.new(url: graphql_url) do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end

    resp = conn.post do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = { query: query }.to_json
    end

    JSON.parse(resp.body)
  end

  def sync_transactions
    first_page = fetch_transactions_from_graphql # TODO handle errors
    total_count = first_page['data']['transactions']['totalCount']
    puts "Total count: #{total_count}"
    offset = 0
    while offset < total_count
      puts "Loading transactions #{offset}"
      page = fetch_transactions_from_graphql(offset: offset)
      transactions = page['data']['transactions']['nodes'].map do |node|
        {
          collective_id: id,
          uuid: node['uuid'],
          amount: node['amount']['value'],
          net_amount: node['netAmount']['value'],
          transaction_type: node['type'],
          transaction_kind: node['kind'],
          transaction_expense_type: node['expense'] ? node['expense']['type'] : nil,
          currency: node['amount']['currency'],
          account: node['type'] == 'DEBIT' ? node['toAccount']['slug'] : node['fromAccount']['slug'],
          created_at: node['createdAt'],
          description: node['description'],
          from_account: node['fromAccount'] ? node['fromAccount']['slug'] : nil,
          to_account: node['toAccount'] ? node['toAccount']['slug'] : nil
        }
      end
      Transaction.upsert_all(transactions, unique_by: :uuid) if transactions.any?
      offset += 100
      sleep 0.5 # Rate limit between pagination requests
    end
    update(balance: current_balance)
  end

  def fetch_transactions_from_graphql(offset: 0)
    graphql_url = "https://opencollective.com/api/graphql/v2?personalToken=#{ENV['OPEN_COLLECTIVE_API_KEY']}"

    query = <<~GRAPHQL
      query Transactions(
        $account: [AccountReferenceInput!]
        $limit: Int
        $offset: Int
      ) {
        transactions(
          account: $account
          limit: $limit
          offset: $offset
        ) {
          offset
          limit
          totalCount
          nodes {
            uuid
            amount {
              value
              currency
            }
            description
            netAmount {
              value
              currency
            }            
            createdAt
            type
            kind
            expense {
              type
            }
            toAccount {
              slug
            }
            fromAccount {
              slug
            }
          }
        }
      }
    GRAPHQL

    conn = Faraday.new(url: graphql_url) do |faraday|
      faraday.headers['User-Agent'] = 'dashboards.ecosyste.ms'
      faraday.headers['X-Source'] = 'dashboards.ecosyste.ms'
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end

    resp = conn.post do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = { query: query, variables: { account: { slug: slug }, limit: 100, offset: offset } }.to_json
    end

    JSON.parse(resp.body)
  end

  before_save :set_total_donations

  def set_total_donations
    self.total_donations = transactions.donations.sum(:net_amount) + transactions.host_fees.sum(:net_amount)
  end

  def total_expenses
    transactions.expenses.sum(:net_amount)
  end

  def current_balance
    transactions.sum(:net_amount)
  end

  def owner_has_sponsors_listing?
    return false if owner.nil?
    owner['metadata'].present? && owner['metadata']['has_sponsors_listing']
  end

  def set_no_funding
    if owner_has_sponsors_listing? || projects_with_repository.empty?
      self.no_funding = false
    else
      self.no_funding = projects_with_repository.all?{|p| p.no_funding? }
    end
  end

  def set_no_license
    if projects_with_repository.empty?
      self.no_license = false
    else
      self.no_license = projects_with_repository.all?{|p| p.no_license? }
    end
  end

  def key_projects
    return [projects.first] if !project_org? || projects_count == 1
    projects_with_repository.source.active.order_by_stars.where(Arel.sql("(repository ->> 'stargazers_count')::int > 0")).first(5)
  end

  def dot_github_repository
    @dot_github_repository ||= projects.find_by_url("https://github.com/#{project_owner}/.github")
  end

  def funders
    transactions.donations
      .group(:account)
      .select('account, SUM(amount) as total')
      .order('total DESC')
  end

  def self.funder_account_names
    Transaction.donations.distinct.pluck(:account)
  end

  def self.sync_funders
    job_index = 0
    funder_account_names.first(50).each do |account|
      collective = Collective.find_or_create_by(slug: account)
      if collective.last_synced_at.nil?
        collective.sync_async(delay: job_index * 30.seconds)
        job_index += 1
      end
    end
  end
end
