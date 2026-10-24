class Package < ApplicationRecord
  belongs_to :project

  counter_culture :project, column_name: 'packages_count', execute_after_commit: true

  validates :name, presence: true
  validates :ecosystem, presence: true

  scope :package_url, ->(package_url) { where(purl: Package.purl_without_version(package_url)) }
  scope :package_urls, ->(package_urls) { where(purl: package_urls.map{|p| Package.purl_without_version(p) }) }

  scope :active, -> { where("(metadata ->> 'status') is null") }
  scope :order_by_rankings, -> { order(Arel.sql("(metadata -> 'rankings' ->> 'average')::numeric asc nulls last")) }

  # Julia's uuid qualifier is required by the PURL spec but General registry names are unique,
  # so packages match with or without it
  IGNORED_QUALIFIERS = { "julia" => %w[uuid] }.freeze

  def self.purl_without_version(purl)
    parsed = Purl.parse(purl.to_s)
    qualifiers = parsed.qualifiers&.except(*IGNORED_QUALIFIERS.fetch(parsed.type, []))
    parsed.with(version: nil, qualifiers: qualifiers.presence).to_s
  end

  def self.convert_ecosystem_to_purl_type(ecosystem)
    case ecosystem.downcase
    when "actions"
      "githubactions"
    when "elpa"
      "melpa"
    when "go"
      "golang"
    when "homebrew"
      "brew"
    when "packagist"
      "composer"
    when "rubygems"
      "gem"
    when "swiftpm"
      "swift"
    else
      ecosystem.downcase
    end
  end

  def registry_name
    metadata&.dig("registry", "name")
  end

  def keywords
    metadata&.dig('keywords')
  end

  def funding
    metadata&.dig('metadata', 'funding')
  end

  def downloads_period
    metadata&.dig('downloads_period')
  end

  def downloads
    metadata&.dig('downloads') || 0
  end

  def dependents
    metadata&.dig('dependents') || 0
  end

  def dependent_repos_count
    metadata&.dig('dependent_repos_count') || 0
  end

  def licenses
    metadata&.dig('licenses')
  end

  def rankings
    metadata&.dig('rankings')
  end

  def registry_url
    metadata&.dig('registry_url')
  end

  def latest_release_number
    metadata&.dig('latest_release_number')
  end

  def status
    metadata&.dig('status')
  end
  
  def description
    metadata&.dig('description')
  end

  def description_with_fallback
    description.presence || project.description
  end

  def versions_count
    metadata['versions_count']
  end

  def latest_release_published_at
    metadata['latest_release_published_at']
  end

  def dependent_packages_count
    metadata['dependent_packages_count'] || 0
  end

  def repo_metadata
    metadata['repo_metadata']
  end

  def maintainers_count
    metadata['maintainers_count']
  end

  def documentation_url
    metadata['documentation_url']
  end

  def registry_url
    metadata['registry_url']
  end

  def homepage_url
    metadata['homepage']
  end

  def repository_url
    metadata['repository_url']
  end

  def last_synced_at
    metadata['last_synced_at']
  end
end
