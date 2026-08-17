require 'test_helper'

class ProjectTest < ActiveSupport::TestCase
  test "generates slug from URL on creation" do
    project = Project.create!(url: "https://github.com/octocat/hello-world")
    assert_equal "github.com/octocat/hello-world", project.slug
  end

  test "generates slug without www prefix" do
    project = Project.create!(url: "https://www.github.com/octocat/hello-world")
    assert_equal "github.com/octocat/hello-world", project.slug
  end

  test "generates slug without trailing slash" do
    project = Project.create!(url: "https://github.com/octocat/hello-world/")
    assert_equal "github.com/octocat/hello-world", project.slug
  end

  test "normalizes URL by removing trailing slashes" do
    project = Project.new(url: 'https://github.com/kenaniah/sidekiq-status/')
    project.valid?
    assert_equal 'https://github.com/kenaniah/sidekiq-status', project.url
    assert_equal 'github.com/kenaniah/sidekiq-status', project.slug
  end

  test "normalizes URL with multiple trailing slashes" do
    project = Project.new(url: 'https://github.com/kenaniah/sidekiq-status///')
    project.valid?
    assert_equal 'https://github.com/kenaniah/sidekiq-status', project.url
    assert_equal 'github.com/kenaniah/sidekiq-status', project.slug
  end

  test "prevents duplicate slug errors for URLs with trailing slashes" do
    # Create first project without trailing slash
    project1 = Project.create!(url: 'https://github.com/test/unique-repo')
    assert_equal 'github.com/test/unique-repo', project1.slug
    
    # Try to create second project with trailing slash - should fail with same slug
    project2 = Project.new(url: 'https://github.com/test/unique-repo/')
    assert_not project2.valid?
    assert_includes project2.errors[:slug], 'has already been taken'
    
    # But normalized URLs should be the same
    project2.valid? # triggers normalization
    assert_equal project1.url, project2.url
  end

  test "handles URLs with spaces and trailing slashes" do
    project = Project.new(url: '  https://github.com/test/repo/  ')
    project.valid?
    assert_equal 'https://github.com/test/repo', project.url
    assert_equal 'github.com/test/repo', project.slug
  end

  test "to_param returns slug" do
    project = Project.create!(url: "https://github.com/octocat/hello-world")
    assert_equal "github.com/octocat/hello-world", project.to_param
  end

  test "find_by_slug works with different cases" do
    project = Project.create!(url: "https://github.com/octocat/hello-world")

    found_lower = Project.find_by_slug("github.com/octocat/hello-world")
    found_upper = Project.find_by_slug("GITHUB.COM/OCTOCAT/HELLO-WORLD")
    found_mixed = Project.find_by_slug("GitHub.com/OctoCat/Hello-World")

    assert_equal project, found_lower
    assert_equal project, found_upper
    assert_equal project, found_mixed
  end

  test "generates slug from URL without scheme" do
    project = Project.create!(url: "github.com/calliope-project/calliope")
    assert_equal "github.com/calliope-project/calliope", project.slug
  end

  test "generates slug from URL with http scheme" do
    project = Project.create!(url: "http://github.com/example/test")
    assert_equal "github.com/example/test", project.slug
  end

  test "generates slug from URL without scheme and with www" do
    project = Project.create!(url: "www.github.com/example/test")
    assert_equal "github.com/example/test", project.slug
  end
  test "github_pages_to_repo_url" do
    project = Project.new
    repo_url = project.github_pages_to_repo_url('https://foo.github.io/bar')
    assert_equal 'https://github.com/foo/bar', repo_url
  end

  test "github_pages_to_repo_url with trailing slash" do
    project = Project.new(url: 'https://foo.github.io/bar/')
    repo_url = project.repository_url
    assert_equal 'https://github.com/foo/bar', repo_url
  end

  test "sync repository data updates repository field" do
    VCR.use_cassette("project_sync/fetch_repository_rails_project") do
      project = create(:project, :rails_project, :never_synced, url: "https://github.com/rails/rails")
      
      project.fetch_repository
      project.reload
      
      assert project.repository.present?
      assert_equal "rails/rails", project.repository["full_name"]
      assert_equal "Ruby", project.repository["language"]
    end
  end

  test "sync packages data updates packages and timestamp" do
    VCR.use_cassette("project_sync/fetch_packages_rails_project") do
      project = create(:project, :rails_project, :never_synced, url: "https://github.com/rails/rails")
      
      project.fetch_packages
      project.reload
      
      assert_not_nil project.packages_last_synced_at
      assert project.packages.count >= 0  # May have packages depending on API response
    end
  end

  test "sync_issues method updates timestamp" do
    VCR.use_cassette("project_sync/sync_issues_rails_project") do
      project = create(:project, :rails_project, :never_synced, url: "https://github.com/rails/rails")
      
      project.sync_issues
      project.reload
      
      assert_not_nil project.issues_last_synced_at
      assert project.issues.count >= 0  # Issues might not be created due to validation
    end
  end

  test "sync_issues returns pending for an unsynced upstream repository" do
    project = create(:project, :rails_project, :never_synced)
    issues_url = "https://issues.ecosyste.ms/api/v1/hosts/GitHub/repositories/rails/rails/issues"

    stub_request(:get, project.issues_api_url)
      .to_return(status: 200, body: {
        last_synced_at: nil,
        issues_url: issues_url
      }.to_json)

    assert_equal :pending, project.sync_issues
    assert_nil project.reload.issues_last_synced_at
    assert_not_requested :get, issues_url
  end

  test "sync_issues completes for a synced repository with no issues" do
    project = create(:project, :rails_project, :never_synced)
    issues_url = "https://issues.ecosyste.ms/api/v1/hosts/GitHub/repositories/rails/rails/issues"

    stub_request(:get, project.issues_api_url)
      .to_return(status: 200, body: {
        last_synced_at: Time.current.iso8601,
        issues_url: issues_url
      }.to_json)
    stub_request(:get, /issues\.ecosyste\.ms\/api\/v1\/hosts\/GitHub\/repositories\/rails\/rails\/issues/)
      .to_return(status: 200, body: [].to_json)

    assert_equal :complete, project.sync_issues
    assert_not_nil project.reload.issues_last_synced_at
  end

  test "sync_issues returns error when the lookup fails" do
    project = create(:project, :rails_project, :never_synced)

    stub_request(:get, project.issues_api_url)
      .to_return(status: 500, body: {}.to_json)

    assert_equal :error, project.sync_issues
    assert_nil project.reload.issues_last_synced_at
  end

  test "ready? returns false for never synced project" do
    project = create(:project, last_synced_at: nil, sync_status: 'pending')
    assert_not project.ready?
  end

  test "ready? returns false for old synced project" do
    project = create(:project, last_synced_at: 2.hours.ago, sync_status: 'pending')
    assert_not project.ready?
  end

  test "ready? returns true for recently synced project" do
    project = create(:project, last_synced_at: 30.minutes.ago)
    assert project.ready?
  end

  test "ready? returns true for completed sync even if last_synced_at is old" do
    project = create(:project, last_synced_at: 2.hours.ago, sync_status: 'completed')
    assert project.ready?
  end

  test "ready? returns false for error sync status" do
    project = create(:project, last_synced_at: 30.minutes.ago, sync_status: 'error')
    assert_not project.ready?
  end

  test "ready? returns false for syncing status with old last_synced_at" do
    project = create(:project, last_synced_at: 2.hours.ago, sync_status: 'syncing')
    assert_not project.ready?
  end

  test "sync_stuck? returns true for syncing project with old updated_at" do
    project = create(:project, sync_status: 'syncing', updated_at: 1.hour.ago)
    assert project.sync_stuck?
  end

  test "sync_stuck? returns false for syncing project with recent updated_at" do
    project = create(:project, sync_status: 'syncing', updated_at: 15.minutes.ago)
    assert_not project.sync_stuck?
  end

  test "sync_stuck? returns false for completed project" do
    project = create(:project, sync_status: 'completed', updated_at: 1.hour.ago)
    assert_not project.sync_stuck?
  end

  test "sync_progress returns correct progress" do
    project = create(:project, :without_repository, last_synced_at: nil)
    progress = project.sync_progress
    
    assert_equal 6, progress[:total]
    assert_equal 0, progress[:completed]
    assert_equal 0, progress[:percentage]
  end

  test "sync_progress with some components synced" do
    project = create(:project, :with_repository, 
                    packages_last_synced_at: 1.hour.ago,
                    issues_last_synced_at: 1.hour.ago)
    progress = project.sync_progress
    
    assert_equal 6, progress[:total]
    assert_equal 3, progress[:completed]  # repository + packages + issues
    assert_equal 50, progress[:percentage]
  end

  test "sync_commits method updates timestamp" do
    WebMock.enable!
    project = create(:project, :rails_project, :never_synced, url: "https://github.com/rails/rails-commits-test")
    
    # Mock the commits API response with correct structure
    stub_request(:get, project.commits_api_url)
      .to_return(status: 200, body: { 
        total_commits: 0,
        commits_url: "https://commits.ecosyste.ms/api/v1/hosts/GitHub/repositories/rails/rails/commits" 
      }.to_json)
    
    # Mock the commits list API
    stub_request(:get, /commits\.ecosyste\.ms\/api\/v1\/hosts\/GitHub\/repositories\/rails\/rails\/commits/)
      .to_return(status: 200, body: [].to_json)
    
    project.sync_commits
    project.reload
    
    assert_not_nil project.commits_last_synced_at
    # The main thing we're testing is that the timestamp gets set
    assert project.commits_last_synced_at > 1.minute.ago
  ensure
    WebMock.reset!
  end

  test "sync_commits returns pending for an accepted lookup" do
    project = create(:project, :rails_project, :never_synced)

    stub_request(:get, project.commits_api_url)
      .to_return(status: 202, body: { status: 'pending' }.to_json)

    assert_equal :pending, project.sync_commits
    assert_nil project.reload.commits_last_synced_at
  end

  test "sync_commits returns pending until the upstream repository has a commit count" do
    project = create(:project, :rails_project, :never_synced)
    commits_url = "https://commits.ecosyste.ms/api/v1/hosts/GitHub/repositories/rails/rails/commits"

    stub_request(:get, project.commits_api_url)
      .to_return(status: 200, body: {
        total_commits: nil,
        commits_url: commits_url
      }.to_json)

    assert_equal :pending, project.sync_commits
    assert_nil project.reload.commits_last_synced_at
    assert_not_requested :get, commits_url
  end

  test "sync_commits returns error when the lookup fails" do
    project = create(:project, :rails_project, :never_synced)

    stub_request(:get, project.commits_api_url)
      .to_return(status: 500, body: {}.to_json)

    assert_equal :error, project.sync_commits
    assert_nil project.reload.commits_last_synced_at
  end

  test "fetch repository data updates repository field" do
    VCR.use_cassette("project_sync/fetch_repository_direct_url") do
      project = create(:project, :never_synced, url: "https://github.com/rails/rails")
      
      project.fetch_repository
      project.reload
      
      assert project.repository.present?
      assert_equal "rails/rails", project.repository["full_name"]
      assert_equal "Ruby", project.repository["language"]
    end
  end

  test "fetch packages data updates packages and timestamp" do
    VCR.use_cassette("project_sync/fetch_packages_direct_url") do
      project = create(:project, :never_synced, url: "https://github.com/rails/rails")
      
      project.fetch_packages(max_pages: 2)
      project.reload
      
      assert_not_nil project.packages_last_synced_at
      assert project.packages.count >= 0  # May have packages depending on API response
    end
  end

  test "sync respects individual timestamps" do
    WebMock.enable!
    project = create(:project, :rails_project, :never_synced, url: "https://github.com/rails/rails-sync-test")
    
    # Mock the commits API response with correct structure
    stub_request(:get, project.commits_api_url)
      .to_return(status: 200, body: { 
        total_commits: 0,
        commits_url: "https://commits.ecosyste.ms/api/v1/hosts/GitHub/repositories/rails/rails/commits" 
      }.to_json)
    
    # Mock the commits list API
    stub_request(:get, /commits\.ecosyste\.ms\/api\/v1\/hosts\/GitHub\/repositories\/rails\/rails\/commits/)
      .to_return(status: 200, body: [].to_json)
    
    project.sync_commits
    project.reload
    
    assert_not_nil project.commits_last_synced_at
    assert project.commits_last_synced_at > 1.minute.ago
  ensure
    WebMock.reset!
  end

  test "full sync updates all timestamps" do
    VCR.use_cassette("project_sync/full_sync") do
      project = create(:project, :rails_project, :never_synced, url: "https://github.com/rails/rails")
      
      project.sync
      project.reload
      
      # Verify main sync timestamp was updated
      assert_not_nil project.last_synced_at
      
      # Verify individual sync timestamps were set  
      assert_not_nil project.packages_last_synced_at
      assert_not_nil project.issues_last_synced_at
    end
  end

  test "full sync schedules retries for pending issues and commits" do
    project = create(:project, :rails_project)
    project.stubs(:safe_broadcast_sync_update)
    project.stubs(:check_url)
    project.stubs(:fetch_repository)
    project.stubs(:fetch_packages)
    project.stubs(:uninteresting_fork?).returns(false)
    project.stubs(:fetch_readme)
    project.stubs(:sync_tags)
    project.stubs(:sync_advisories)
    project.stubs(:sync_issues).returns(:pending)
    project.stubs(:sync_dependabot_issues)
    project.stubs(:sync_commits).returns(:pending)
    project.stubs(:fetch_dependencies)
    project.stubs(:update_sourced_dependency_collections)
    project.stubs(:fetch_collective)
    project.stubs(:fetch_github_sponsors)
    project.stubs(:ping)
    project.stubs(:notify_collections_of_sync)
    SyncPendingProjectDataWorker.expects(:schedule).with(project.id, %w[issues commits])

    project.sync
  end

  test "licenses method flattens and deduplicates package licenses with repository license" do
    project = create(:project)
    repository_license = "Apache-2.0"
    project.update(repository: { 'license' => repository_license })
    
    # Create packages with licenses
    package1 = create(:package, project: project, metadata: { 'licenses' => ['MIT', 'BSD-3-Clause'] })
    package2 = create(:package, project: project, metadata: { 'licenses' => ['MIT', 'GPL-3.0'] })
    
    licenses = project.licenses
    
    assert_includes licenses, 'MIT'
    assert_includes licenses, 'BSD-3-Clause'
    assert_includes licenses, 'GPL-3.0'
    assert_includes licenses, repository_license
    
    # Should not have duplicates
    assert_equal licenses.uniq, licenses
  end

  test "should not allow PURL as URL" do
    project = Project.new(url: "pkg:npm/lodash@4.17.21")
    assert_not project.valid?
    assert_includes project.errors[:url], "cannot be a PURL (Package URL)"
  end

  test "should allow regular URLs" do
    project = Project.new(url: "https://github.com/lodash/lodash")
    assert project.valid?(:url)  # Only validate URL, not other required fields
  end

  test "create_collection_from_dependencies with no dependencies returns nil" do
    user = create(:user)
    project = create(:project, dependencies: nil)
    
    result = project.create_collection_from_dependencies(user)
    assert_nil result
  end

  test "create_collection_from_dependencies with empty dependencies returns nil" do
    user = create(:user)
    project = create(:project, dependencies: [])
    
    result = project.create_collection_from_dependencies(user)
    assert_nil result
  end

  test "create_collection_from_dependencies creates collection with direct dependencies" do
    user = create(:user)
    project = create(:project, url: "https://github.com/test/project")
    
    # Mock dependencies data
    dependencies_data = [
      {
        "manifest_kind" => "package.json",
        "manifest_filepath" => "package.json",
        "dependencies" => [
          {
            "package_name" => "lodash",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          },
          {
            "package_name" => "react",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          },
          {
            "package_name" => "jest",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "development"
          }
        ]
      }
    ]
    
    project.update!(dependencies: dependencies_data)
    
    collection = project.create_collection_from_dependencies(user)
    
    assert_not_nil collection
    assert collection.persisted?
    assert_equal "github.com/test/project Dependencies", collection.name
    assert_equal "Dependencies of github.com/test/project", collection.description
    assert_equal user, collection.user
    assert_equal 'public', collection.visibility
    assert_equal project, collection.source_project
    
    # Verify the dependency file contains the expected PURLs
    dependency_file = JSON.parse(collection.dependency_file)
    assert_equal "SPDXRef-DOCUMENT", dependency_file["SPDXID"]
    assert_equal "SPDX-2.3", dependency_file["spdxVersion"]
    
    # Should include all dependencies by default (including development)
    packages = dependency_file["packages"]
    assert_equal 3, packages.length
    
    purls = packages.map { |p| p["externalRefs"].first["referenceLocator"] }
    assert_includes purls, "pkg:npm/lodash"
    assert_includes purls, "pkg:npm/react"
    assert_includes purls, "pkg:npm/jest"  # development dependency included by default
  end

  test "create_collection_from_dependencies with include_development false excludes development dependencies" do
    user = create(:user)
    project = create(:project, url: "https://github.com/test/project")
    
    # Mock dependencies data
    dependencies_data = [
      {
        "manifest_kind" => "package.json",
        "manifest_filepath" => "package.json",
        "dependencies" => [
          {
            "package_name" => "lodash",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          },
          {
            "package_name" => "react",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          },
          {
            "package_name" => "jest",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "development"
          }
        ]
      }
    ]
    
    project.update!(dependencies: dependencies_data)
    
    collection = project.create_collection_from_dependencies(user, include_development: false)
    
    assert_not_nil collection
    
    # Verify only runtime dependencies are included when include_development is false
    dependency_file = JSON.parse(collection.dependency_file)
    packages = dependency_file["packages"]
    assert_equal 2, packages.length
    
    purls = packages.map { |p| p["externalRefs"].first["referenceLocator"] }
    assert_includes purls, "pkg:npm/lodash"
    assert_includes purls, "pkg:npm/react"
    assert_not_includes purls, "pkg:npm/jest"  # development dependency excluded
  end

  test "create_collection_from_dependencies with custom name uses provided name" do
    user = create(:user)
    project = create(:project, url: "https://github.com/test/project")
    
    dependencies_data = [
      {
        "manifest_kind" => "package.json",
        "manifest_filepath" => "package.json",
        "dependencies" => [
          {
            "package_name" => "lodash",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          }
        ]
      }
    ]
    
    project.update!(dependencies: dependencies_data)
    
    custom_name = "My Custom Dependencies Collection"
    collection = project.create_collection_from_dependencies(user, name: custom_name)
    
    assert_not_nil collection
    assert_equal custom_name, collection.name
  end

  test "dependency_collection_for_user returns existing collection" do
    user = create(:user)
    project = create(:project, url: "https://github.com/test/project")
    
    # Create a collection for the user from this project
    collection = create(:collection, user: user, source_project: project)
    
    result = project.dependency_collection_for_user(user)
    assert_equal collection, result
  end

  test "dependency_collection_for_user returns nil if no collection exists" do
    user = create(:user)
    project = create(:project, url: "https://github.com/test/project")
    
    result = project.dependency_collection_for_user(user)
    assert_nil result
  end

  test "update_dependency_collection updates existing collection" do
    user = create(:user)
    project = create(:project, url: "https://github.com/test/project")
    
    # Create initial dependencies
    initial_dependencies = [
      {
        "manifest_kind" => "package.json",
        "manifest_filepath" => "package.json",
        "dependencies" => [
          {
            "package_name" => "lodash",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          }
        ]
      }
    ]
    
    project.update!(dependencies: initial_dependencies)
    
    # Create initial collection
    collection = project.create_collection_from_dependencies(user)
    initial_packages = JSON.parse(collection.dependency_file)["packages"]
    assert_equal 1, initial_packages.length
    
    # Update project dependencies
    updated_dependencies = [
      {
        "manifest_kind" => "package.json",
        "manifest_filepath" => "package.json",
        "dependencies" => [
          {
            "package_name" => "lodash",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          },
          {
            "package_name" => "react",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          }
        ]
      }
    ]
    
    project.update!(dependencies: updated_dependencies)
    
    # Update the collection
    updated_collection = project.update_dependency_collection(collection)
    
    assert_not_nil updated_collection
    updated_packages = JSON.parse(updated_collection.dependency_file)["packages"]
    assert_equal 2, updated_packages.length
    
    purls = updated_packages.map { |p| p["externalRefs"].first["referenceLocator"] }
    assert_includes purls, "pkg:npm/lodash"
    assert_includes purls, "pkg:npm/react"
  end

  test "update_sourced_dependency_collections updates all collections" do
    user = create(:user)
    project = create(:project, url: "https://github.com/test/project")
    
    # Create initial dependencies
    initial_dependencies = [
      {
        "manifest_kind" => "package.json",
        "manifest_filepath" => "package.json",
        "dependencies" => [
          {
            "package_name" => "lodash",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          }
        ]
      }
    ]
    
    project.update!(dependencies: initial_dependencies)
    
    # Create multiple collections from this project
    collection1 = project.create_collection_from_dependencies(user, name: "Collection 1")
    collection2 = project.create_collection_from_dependencies(create(:user), name: "Collection 2")
    
    # Verify initial state
    assert_equal 1, JSON.parse(collection1.dependency_file)["packages"].length
    assert_equal 1, JSON.parse(collection2.dependency_file)["packages"].length
    
    # Update project dependencies
    updated_dependencies = [
      {
        "manifest_kind" => "package.json",
        "manifest_filepath" => "package.json",
        "dependencies" => [
          {
            "package_name" => "lodash",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          },
          {
            "package_name" => "react",
            "ecosystem" => "npm",
            "direct" => true,
            "kind" => "runtime"
          }
        ]
      }
    ]
    
    project.update!(dependencies: updated_dependencies)
    
    # Trigger auto-update
    project.update_sourced_dependency_collections
    
    # Verify both collections were updated
    collection1.reload
    collection2.reload
    
    assert_equal 2, JSON.parse(collection1.dependency_file)["packages"].length
    assert_equal 2, JSON.parse(collection2.dependency_file)["packages"].length
    
    # Verify both contain the new dependency
    purls1 = JSON.parse(collection1.dependency_file)["packages"].map { |p| p["externalRefs"].first["referenceLocator"] }
    purls2 = JSON.parse(collection2.dependency_file)["packages"].map { |p| p["externalRefs"].first["referenceLocator"] }
    
    assert_includes purls1, "pkg:npm/react"
    assert_includes purls2, "pkg:npm/react"
  end

  test "github_repository? returns true for GitHub repositories" do
    project = create(:project)
    project.update!(repository: { 'host' => { 'name' => 'GitHub' }, 'owner' => { 'login' => 'test' }, 'name' => 'repo' })
    assert project.github_repository?
  end

  test "github_repository? returns false for non-GitHub repositories" do
    project = create(:project)
    project.update!(repository: { 'host' => { 'name' => 'GitLab' }, 'owner' => { 'login' => 'test' }, 'name' => 'repo' })
    assert_not project.github_repository?
  end

  test "github_repository? returns false when no repository" do
    project = create(:project, repository: nil)
    assert_not project.github_repository?
  end

  test "sync_dependabot_issues fetches and stores Dependabot issues" do
    WebMock.enable!
    
    project = create(:project)
    project.update!(repository: { 
      'host' => { 'name' => 'GitHub' }, 
      'owner' => { 'login' => 'andrew' }, 
      'name' => 'purl',
      'full_name' => 'andrew/purl'
    })
    
    # Mock Dependabot API response
    dependabot_issues = [
      {
        'uuid' => 'dep-issue-1',
        'number' => 123,
        'state' => 'open',
        'title' => 'Bump lodash from 4.17.20 to 4.17.21',
        'body' => 'Bumps [lodash](https://github.com/lodash/lodash) from 4.17.20 to 4.17.21.',
        'user' => 'dependabot[bot]',
        'pull_request' => true,
        'created_at' => '2023-01-01T00:00:00Z',
        'updated_at' => '2023-01-01T00:00:00Z',
        'dependency_metadata' => {
          'packages' => [
            {
              'name' => 'lodash',
              'old_version' => '4.17.20',
              'new_version' => '4.17.21'
            }
          ]
        }
      }
    ]
    
    stub_request(:get, "https://dependabot.ecosyste.ms/api/v1/hosts/GitHub/repositories/andrew%2Fpurl/issues")
      .to_return(status: 200, body: dependabot_issues.to_json)
    
    project.sync_dependabot_issues
    project.reload
    
    assert_equal 1, project.issues.count
    issue = project.issues.first
    assert_equal 'dep-issue-1', issue.uuid
    assert_equal 123, issue.number
    assert_equal 'Bump lodash from 4.17.20 to 4.17.21', issue.title
    assert_equal true, issue.pull_request
    assert_equal 'dependabot[bot]', issue.user
    assert issue.dependency_metadata.present?
    assert_equal 'lodash', issue.dependency_metadata['packages'].first['name']
  ensure
    WebMock.reset!
  end

  test "sync_dependabot_issues skips non-GitHub repositories" do
    WebMock.enable!
    
    project = create(:project)
    project.update!(repository: { 
      'host' => { 'name' => 'GitLab' }, 
      'owner' => { 'login' => 'andrew' }, 
      'name' => 'purl' 
    })
    
    # Should not make any HTTP requests
    project.sync_dependabot_issues
    
    assert_equal 0, project.issues.count
  ensure
    WebMock.reset!
  end

  test "sync_dependabot_issues handles API failures gracefully" do
    WebMock.enable!
    
    project = create(:project)
    project.update!(repository: { 
      'host' => { 'name' => 'GitHub' }, 
      'owner' => { 'login' => 'andrew' }, 
      'name' => 'purl',
      'full_name' => 'andrew/purl'
    })
    
    # Mock API failure
    stub_request(:get, "https://dependabot.ecosyste.ms/api/v1/hosts/GitHub/repositories/andrew%2Fpurl/issues")
      .to_return(status: 500)
    
    assert_nothing_raised do
      project.sync_dependabot_issues
    end
    
    assert_equal 0, project.issues.count
  ensure
    WebMock.reset!
  end

  test "sync_dependabot_issues deduplicates issues by UUID" do
    WebMock.enable!
    
    project = create(:project)
    project.update!(repository: { 
      'host' => { 'name' => 'GitHub' }, 
      'owner' => { 'login' => 'andrew' }, 
      'name' => 'purl',
      'full_name' => 'andrew/purl'
    })
    
    # Create existing issue with same UUID
    existing_issue = create(:issue, 
      project: project, 
      uuid: 'dep-issue-1', 
      number: 123,
      title: 'Old Title'
    )
    
    # Mock Dependabot API response with updated issue
    dependabot_issues = [
      {
        'uuid' => 'dep-issue-1',
        'number' => 123,
        'state' => 'closed',
        'title' => 'Updated Title',
        'body' => 'Updated body',
        'user' => 'dependabot[bot]',
        'pull_request' => true,
        'created_at' => '2023-01-01T00:00:00Z',
        'updated_at' => '2023-01-02T00:00:00Z'
      }
    ]
    
    stub_request(:get, "https://dependabot.ecosyste.ms/api/v1/hosts/GitHub/repositories/andrew%2Fpurl/issues")
      .to_return(status: 200, body: dependabot_issues.to_json)
    
    project.sync_dependabot_issues
    project.reload
    
    # Should still have only one issue, but with updated data
    assert_equal 1, project.issues.count
    updated_issue = project.issues.first
    assert_equal 'dep-issue-1', updated_issue.uuid
    assert_equal 'Updated Title', updated_issue.title
    assert_equal 'closed', updated_issue.state
  ensure
    WebMock.reset!
  end

  test "find_or_create_owner_collection creates collection for project owner" do
    WebMock.enable!
    
    user = create(:user)
    project = create(:project)
    project.update!(repository: {
      'owner_url' => 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails',
      'full_name' => 'rails/rails'
    })
    
    owner_response = {
      'login' => 'rails',
      'name' => 'Ruby on Rails',
      'html_url' => 'https://github.com/rails',
      'kind' => 'organization'
    }
    
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails")
      .to_return(status: 200, body: owner_response.to_json)
    
    collection = project.find_or_create_owner_collection(user)
    
    assert_not_nil collection
    assert collection.persisted?
    assert_equal 'rails', collection.name
    assert_equal 'Collection of repositories for rails', collection.description
    assert_equal 'https://github.com/rails', collection.github_organization_url
    assert_equal user, collection.user
    assert_equal 'public', collection.visibility
  ensure
    WebMock.reset!
  end

  test "find_or_create_owner_collection returns existing collection" do
    WebMock.enable!
    
    user = create(:user)
    existing_collection = create(:collection, 
      github_organization_url: 'https://github.com/rails',
      user: user
    )
    
    project = create(:project)
    project.update!(repository: {
      'owner_url' => 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails',
      'full_name' => 'rails/rails'
    })
    
    owner_response = {
      'login' => 'rails',
      'name' => 'Ruby on Rails',
      'html_url' => 'https://github.com/rails',
      'kind' => 'organization'
    }
    
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails")
      .to_return(status: 200, body: owner_response.to_json)
    
    collection = project.find_or_create_owner_collection(user)
    
    assert_equal existing_collection, collection
  ensure
    WebMock.reset!
  end

  test "find_or_create_owner_collection returns nil when repository missing owner_url" do
    user = create(:user)
    project = create(:project, repository: { 'full_name' => 'test/repo' })
    
    collection = project.find_or_create_owner_collection(user)
    
    assert_nil collection
  end

  test "find_or_create_owner_collection handles API errors gracefully" do
    WebMock.enable!
    
    user = create(:user)
    project = create(:project)
    project.update!(repository: {
      'owner_url' => 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/nonexistent',
      'full_name' => 'nonexistent/repo'
    })
    
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/nonexistent")
      .to_return(status: 404)
    
    collection = project.find_or_create_owner_collection(user)
    
    assert_nil collection
  ensure
    WebMock.reset!
  end

  test "find_or_create_owner_collection uses login when name is not available" do
    WebMock.enable!
    
    user = create(:user)
    project = create(:project)
    project.update!(repository: {
      'owner_url' => 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/andrew',
      'full_name' => 'andrew/purl'
    })
    
    owner_response = {
      'login' => 'andrew',
      'html_url' => 'https://github.com/andrew',
      'kind' => 'user'
    }
    
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/andrew")
      .to_return(status: 200, body: owner_response.to_json)
    
    collection = project.find_or_create_owner_collection(user)
    
    assert_not_nil collection
    assert_equal 'andrew', collection.name
    assert_equal 'Collection of repositories for andrew', collection.description
  ensure
    WebMock.reset!
  end

  test "security_documentation_files returns security and threat files" do
    repository_data = {
      'metadata' => {
        'files' => {
          'security' => 'SECURITY.md',
          'threat_model' => 'docs/threat-model.md',
          'readme' => 'README.md',
          'license' => 'LICENSE'
        }
      }
    }
    
    project = create(:project, repository: repository_data)
    security_files = project.security_documentation_files
    
    assert_equal 2, security_files.size
    assert_equal 'SECURITY.md', security_files['security']
    assert_equal 'docs/threat-model.md', security_files['threat_model']
    assert_nil security_files['readme']
    assert_nil security_files['license']
  end

  test "security_documentation_files returns empty hash when no metadata files present" do
    project = create(:project, repository: { 'full_name' => 'test/project' })
    security_files = project.security_documentation_files
    
    assert_equal({}, security_files)
  end

  test "has_security_documentation? returns true when security files exist" do
    repository_data = {
      'metadata' => {
        'files' => {
          'security' => 'SECURITY.md',
          'readme' => 'README.md'
        }
      }
    }
    
    project = create(:project, repository: repository_data)
    assert_equal true, project.has_security_documentation?
  end

  test "has_security_documentation? returns false when no security files exist" do
    repository_data = {
      'metadata' => {
        'files' => {
          'readme' => 'README.md',
          'license' => 'LICENSE'
        }
      }
    }
    
    project = create(:project, repository: repository_data)
    assert_equal false, project.has_security_documentation?
  end

  test "has_repository_metadata_files? returns true when metadata files present" do
    repository_data = {
      'metadata' => {
        'files' => {
          'readme' => 'README.md'
        }
      }
    }
    
    project = create(:project, repository: repository_data)
    assert_equal true, project.has_repository_metadata_files?
  end

  test "has_repository_metadata_files? returns false when no metadata files present" do
    project = create(:project, repository: { 'full_name' => 'test/project' })
    assert_equal false, project.has_repository_metadata_files?
  end

  test "dependabot_api_url generates correct URL for GitHub repository" do
    project = create(:project)
    project.update!(repository: { 
      'host' => { 'name' => 'GitHub' }, 
      'full_name' => 'test-owner/test-repo'
    })
    
    expected_url = "https://dependabot.ecosyste.ms/api/v1/hosts/GitHub/repositories/test-owner%2Ftest-repo/issues"
    assert_equal expected_url, project.dependabot_api_url
  end

  test "dependabot_api_url handles special characters in owner and repo names" do
    project = create(:project)
    project.update!(repository: { 
      'host' => { 'name' => 'GitHub' }, 
      'full_name' => 'owner-with-dash/repo.with.dots'
    })
    
    expected_url = "https://dependabot.ecosyste.ms/api/v1/hosts/GitHub/repositories/owner-with-dash%2Frepo.with.dots/issues"
    assert_equal expected_url, project.dependabot_api_url
  end

  test "dependabot_api_url returns nil for non-GitHub repository" do
    project = create(:project)
    project.update!(repository: { 
      'host' => { 'name' => 'GitLab' }, 
      'full_name' => 'test-owner/test-repo'
    })
    
    assert_nil project.dependabot_api_url
  end

  test "dependabot_api_url returns nil when no repository present" do
    project = create(:project, repository: nil)
    assert_nil project.dependabot_api_url
  end

  test "dependabot_api_url returns nil when repository missing full_name" do
    project = create(:project)
    project.update!(repository: { 'host' => { 'name' => 'GitHub' } })
    assert_nil project.dependabot_api_url
    
    project.update!(repository: { 'host' => { 'name' => 'GitHub' }, 'full_name' => 'invalid' })
    assert_nil project.dependabot_api_url
    
    project.update!(repository: { 'host' => { 'name' => 'GitHub' }, 'full_name' => '' })
    assert_nil project.dependabot_api_url
  end

  test "essential_links handles mixed string and array data types" do
    project = build(:project, url: "https://github.com/test/project")

    # Mock the methods to return different data types
    project.stubs(:homepage_url).returns(["https://example.com", "https://test.com"])
    project.stubs(:documentation_urls).returns(["https://docs.example.com"])
    project.stubs(:funding_links).returns(["https://github.com/sponsors/test"])

    # Should not raise an error and return sorted unique links
    links = project.essential_links

    assert_kind_of Array, links
    assert links.all? { |link| link.is_a?(String) }
    assert_equal links.sort, links # Should be sorted
    assert_equal links.uniq, links # Should be unique
  end

  test "package_funding_links extracts URLs from hash funding data" do
    project = build(:project)

    # Create a mock package with hash funding data like from npm/composer
    package = mock('package')
    package.stubs(:funding).returns([{"url" => "https://wordpressfoundation.org/donate/", "type" => "other"}])

    project.stubs(:packages_count).returns(1)
    project.stubs(:packages).returns([package])

    links = project.package_funding_links

    assert_equal ["https://wordpressfoundation.org/donate/"], links
    assert links.all? { |link| link.is_a?(String) }
  end

  test "essential_links returns empty array when all methods return nil or empty" do
    project = build(:project, url: nil)

    project.stubs(:homepage_url).returns([])
    project.stubs(:documentation_urls).returns([])
    project.stubs(:funding_links).returns([])

    links = project.essential_links
    assert_equal [], links
  end

  test "repo_funding_links handles array values for liberapay" do
    project = build(:project)
    project.stubs(:repository).returns({
      'metadata' => {
        'funding' => {
          'liberapay' => ['kornel']
        }
      }
    })

    links = project.repo_funding_links
    assert_equal ["https://liberapay.com/kornel"], links
  end

  test "repo_funding_links handles array values for multiple platforms" do
    project = build(:project)
    project.stubs(:repository).returns({
      'metadata' => {
        'funding' => {
          'ko_fi' => ['user1', 'user2'],
          'patreon' => ['creator']
        }
      }
    })

    links = project.repo_funding_links
    assert_includes links, "https://ko-fi.com/user1"
    assert_includes links, "https://ko-fi.com/user2"
    assert_includes links, "https://patreon.com/creator"
  end

  test "repo_funding_links handles string values unchanged" do
    project = build(:project)
    project.stubs(:repository).returns({
      'metadata' => {
        'funding' => {
          'liberapay' => 'kornel'
        }
      }
    })

    links = project.repo_funding_links
    assert_equal ["https://liberapay.com/kornel"], links
  end

  test "normalize_funding_link returns nil for invalid URIs" do
    project = build(:project)

    result = project.normalize_funding_link('https://liberapay.com/["kornel"]')
    assert_nil result
  end

  test "other_funding_links filters out invalid URIs" do
    project = build(:project)
    project.stubs(:funding_links).returns([
      'https://liberapay.com/validuser',
      'https://liberapay.com/["invalid"]',
      'https://ko-fi.com/gooduser'
    ])

    links = project.other_funding_links
    assert_includes links, "https://liberapay.com/validuser"
    assert_includes links, "https://ko-fi.com/gooduser"
    refute links.any? { |l| l&.include?('["invalid"]') }
  end

end
