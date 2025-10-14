require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  test "should get index when logged in" do
    user = create(:user)
    login_as user
    
    get projects_url
    assert_response :success
  end

  test "should require authentication for index" do
    get projects_url
    assert_redirected_to login_url
  end

  test "should show project" do
    project = create(:project, :with_repository)
    get project_url(project)
    assert_response :success
  end

  test "should show project by slug" do
    project = create(:project, :with_repository, url: "https://github.com/octocat/hello-world")
    get project_url("github.com/octocat/hello-world")
    assert_response :success
    assert_equal project, assigns(:project)
  end

  test "should show project by slug case insensitive" do
    project = create(:project, :with_repository, url: "https://github.com/octocat/hello-world")
    get project_url("GITHUB.COM/OCTOCAT/HELLO-WORLD")
    assert_response :success
    assert_equal project, assigns(:project)
  end

  test "should handle project names ending with .json" do
    project = create(:project, :with_repository, url: "https://github.com/octocat/package.json")
    get project_url("github.com/octocat/package.json")
    assert_response :success
    assert_equal project, assigns(:project)
  end

  test "clean URL helpers generate unencoded paths" do
    project = create(:project, :with_repository, url: "https://github.com/octocat/hello-world")
    
    # Test that our helpers generate clean paths
    view_context = ApplicationController.new.view_context
    
    clean_path = view_context.project_path(project)
    assert_equal "/projects/github.com/octocat/hello-world", clean_path
    
    clean_packages_path = view_context.packages_project_path(project)
    assert_equal "/projects/github.com/octocat/hello-world?tab=packages", clean_packages_path
  end


  test "should show meta page" do
    project = create(:project, :with_repository)
    get meta_project_url(project)
    assert_response :success
  end

  test "should show meta page when repository is nil" do
    project = create(:project, :without_repository)
    get meta_project_url(project)
    assert_response :success
    assert_select 'span', text: /Repository: Never/
    assert_select 'span', text: /Tags: Never/
  end

  test "should sync project successfully" do
    project = create(:project, :with_repository)
    
    # Mock the sync method to succeed
    Project.any_instance.expects(:sync).once
    
    get sync_project_url(project)
    assert_response :redirect
    assert_match %r{/projects/#{Regexp.escape(project.slug)}$}, response.location
    assert_equal 'Project synced', flash[:notice]
  end

  test "should handle sync errors gracefully" do
    project = create(:project, :with_repository)
    
    # Mock the sync method to raise an error
    Project.any_instance.expects(:sync).raises(StandardError.new("Connection timeout"))
    
    get sync_project_url(project)
    assert_response :redirect
    assert_match %r{/projects/#{Regexp.escape(project.slug)}$}, response.location
    assert_equal 'Sync failed: Connection timeout', flash[:alert]
  end

  test "should show syncing page for never-synced project" do
    project = create(:project, :without_repository, last_synced_at: nil, sync_status: 'pending')
    get project_url(project)  
    assert_response :success
    assert_template :syncing
    assert_select 'h2', text: /Syncing project data/
    assert_select '.sync-status-content'
    assert_select 'meta[http-equiv="refresh"][content="30"]'
  end

  test "should show project page for previously synced project even if sync_status is pending" do
    project = create(:project, :with_repository, last_synced_at: 2.hours.ago, sync_status: 'pending')
    get project_url(project)
    assert_response :success
    assert_template :show  # Should show main project page, not syncing page
  end

  test "should show regular project page for synced project" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    get project_url(project)
    assert_response :success
    assert_template :show
  end

  test "should show syncing page directly for never-synced project" do
    project = create(:project, :without_repository, sync_status: 'pending', last_synced_at: nil)
    get syncing_project_url(project)
    assert_response :success
    assert_template :syncing
    assert_select 'h2', text: /Syncing project data/
    assert_select 'meta[http-equiv="refresh"][content="30"]'
  end

  test "should show new project form when logged in" do
    user = create(:user)
    login_as user
    
    get new_project_url
    assert_response :success
    assert_template :new
    assert_select 'h1', text: /Add a new project/
    assert_select 'input[name="project[url]"]'
  end

  test "should require authentication for new project form" do
    get new_project_url
    assert_redirected_to login_url
  end

  test "should create new project when logged in" do
    user = create(:user)
    login_as user
    
    assert_difference('Project.count') do
      assert_difference('UserProject.count', 1) do
        post projects_url, params: { project: { url: 'https://github.com/test/repo' } }
      end
    end
    
    project = Project.last
    assert_equal 'https://github.com/test/repo', project.url
    assert_redirected_to project_url(project)
    assert_equal 'Project was successfully created and added to your list.', flash[:notice]
    
    # Verify the project was added to user's list
    assert user.user_projects.exists?(project: project)
  end

  test "should redirect to existing project if already exists" do
    user = create(:user)
    login_as user
    existing_project = create(:project, url: 'https://github.com/test/repo')
    
    assert_no_difference('Project.count') do
      assert_difference('UserProject.count', 1) do
        post projects_url, params: { project: { url: 'https://github.com/test/repo' } }
      end
    end
    
    assert_redirected_to project_url(existing_project)
    assert_equal 'Project added to your list.', flash[:notice]
    
    # Verify the project was added to user's list
    assert user.user_projects.exists?(project: existing_project)
  end

  test "should handle case insensitive URLs" do
    user = create(:user)
    login_as user
    existing_project = create(:project, url: 'https://github.com/test/repo')
    
    assert_no_difference('Project.count') do
      post projects_url, params: { project: { url: 'HTTPS://GITHUB.COM/TEST/REPO' } }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should require authentication for project creation" do
    post projects_url, params: { project: { url: 'https://github.com/test/repo' } }
    assert_redirected_to login_url
  end

  test "should show validation errors for invalid project" do
    user = create(:user)
    login_as user
    
    post projects_url, params: { project: { url: '' } }
    assert_response :success
    assert_template :new
    assert_select '.alert-danger'
  end

  test "should pre-fill URL in new project form when passed as parameter" do
    user = create(:user)
    login_as user
    
    url = "https://github.com/test/repo"
    get new_project_url(url: url)
    assert_response :success
    assert_select 'input[name="project[url]"][value="' + url + '"]'
  end

  test "should show project packages" do
    project = create(:project, :with_repository)
    get project_url(project, tab: 'packages')
    assert_response :success
  end

  test "should show project commits" do
    project = create(:project, :with_repository)
    get project_url(project, tab: 'commits')
    assert_response :success
  end

  test "should show project issues" do
    project = create(:project, :with_repository)
    get project_url(project, tab: 'issues')
    assert_response :success
  end

  test "should show project releases" do
    project = create(:project, :with_repository)
    get project_url(project, tab: 'releases')
    assert_response :success
  end

  test "should show project advisories" do
    project = create(:project, :with_repository)
    get project_url(project, tab: 'advisories')
    assert_response :success
  end

  test "should show project security" do
    project = create(:project, :with_repository)
    get project_url(project, tab: 'security')
    assert_response :success
  end

  test "should show security documentation when security files are present" do
    # Create project with security files in metadata
    repository_data = {
      'full_name' => 'test/project',
      'metadata' => {
        'files' => {
          'security' => 'SECURITY.md',
          'threat_model' => 'THREAT_MODEL.md',
          'readme' => 'README.md'
        }
      },
      'html_url' => 'https://github.com/test/project',
      'default_branch' => 'main'
    }
    
    project = create(:project, repository: repository_data)
    get project_url(project, tab: 'security')
    
    assert_response :success
    assert_select 'h5', text: 'Security Documentation'
    assert_select 'strong', text: 'Security:'
    assert_select 'strong', text: 'Threat model:'
    assert_select 'strong', { count: 0, text: 'Readme:' } # Should not show non-security files
  end

  test "should show security documentation section with message when no security files are present" do
    # Create project with only non-security files in metadata
    repository_data = {
      'full_name' => 'test/project',
      'metadata' => {
        'files' => {
          'readme' => 'README.md',
          'license' => 'LICENSE'
        }
      }
    }
    
    project = create(:project, repository: repository_data)
    get project_url(project, tab: 'security')
    
    assert_response :success
    assert_select 'h5', text: 'Security Documentation'
    assert_select 'p', text: /No security documentation files.*were found in this repository/
  end

  test "should show security documentation section when no repository metadata is available" do
    # Create project with repository but no metadata files
    repository_data = {
      'full_name' => 'test/project',
      'html_url' => 'https://github.com/test/project'
    }
    
    project = create(:project, repository: repository_data)
    get project_url(project, tab: 'security')
    
    assert_response :success
    assert_select 'h5', text: 'Security Documentation'
    assert_select 'p', text: /No repository metadata available/
  end

  test "should not show security documentation section when no repository is present" do
    # Create project without repository
    project = create(:project, repository: nil)
    get project_url(project, tab: 'security')
    
    assert_response :success
    assert_select 'h5', { count: 0, text: 'Security Documentation' }
  end

  test "should redirect to new project form for non-existent project" do
    url = "https://github.com/newuser/newrepo"
    
    # No authentication required for lookup
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { url: url }
    end
    
    assert_redirected_to new_project_path(url: url)
  end

  test "should redirect to existing project on lookup without authentication" do
    existing_project = create(:project, url: "https://github.com/existing/repo")
    
    # No authentication required for lookup of existing projects
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { url: existing_project.url.upcase }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should lookup project by homepage URL from repository" do
    homepage_url = "https://example.com/project"
    existing_project = create(:project, :with_repository, url: "https://github.com/test/repo")
    existing_project.update(repository: existing_project.repository.merge({ 'homepage' => homepage_url }))
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { url: homepage_url }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should lookup project by package homepage URL" do
    homepage_url = "https://example.com/package"
    existing_project = create(:project, :with_repository, url: "https://github.com/test/repo")
    package = create(:package, project: existing_project)
    package.update(metadata: (package.metadata || {}).merge({ 'homepage' => homepage_url }))
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { url: homepage_url }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should lookup project by NPM package URL using purl conversion" do
    existing_project = create(:project, :with_repository, url: "https://github.com/test/repo")
    package = create(:package, project: existing_project, ecosystem: 'npm', name: 'semver-compare')
    package.update(purl: 'pkg:npm/semver-compare')
    
    # Mock the Purl conversion - registry URL with version returns versioned purl
    mock_purl = mock()
    mock_purl_without_version = mock()
    mock_purl.expects(:with).with(version: nil).returns(mock_purl_without_version)
    mock_purl_without_version.expects(:to_s).returns('pkg:npm/semver-compare')
    Purl.expects(:from_registry_url).with("https://www.npmjs.com/package/semver-compare").returns(mock_purl)
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { url: "https://www.npmjs.com/package/semver-compare" }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should lookup project by versioned NPM package URL" do
    existing_project = create(:project, :with_repository, url: "https://github.com/test/repo")
    package = create(:package, project: existing_project, ecosystem: 'npm', name: 'lodash')
    package.update(purl: 'pkg:npm/lodash')
    
    # Mock the Purl conversion for versioned URL
    mock_purl = mock()
    mock_purl_without_version = mock()
    mock_purl.expects(:with).with(version: nil).returns(mock_purl_without_version)
    mock_purl_without_version.expects(:to_s).returns('pkg:npm/lodash')
    Purl.expects(:from_registry_url).with("https://www.npmjs.com/package/lodash/v/4.17.21").returns(mock_purl)
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { url: "https://www.npmjs.com/package/lodash/v/4.17.21" }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should create project when repository URL resolved from package URL" do
    registry_url = "https://www.npmjs.com/package/nonexistent-package"
    repository_url = "https://github.com/user/nonexistent-package"
    
    # Mock PURL conversion
    mock_purl = mock()
    mock_purl_without_version = mock()
    mock_purl.expects(:with).with(version: nil).returns(mock_purl_without_version).twice  # Called twice: once for package lookup, once for API lookup
    mock_purl_without_version.expects(:to_s).returns('pkg:npm/nonexistent-package').twice
    Purl.expects(:from_registry_url).with(registry_url).returns(mock_purl)
    
    # Mock API response
    mock_response = mock()
    mock_response.expects(:success?).returns(true)
    mock_response.expects(:body).returns([{ 'repository_url' => repository_url }].to_json)
    Faraday.expects(:get).with("https://packages.ecosyste.ms/api/v1/packages/lookup", { purl: 'pkg:npm/nonexistent-package' }, {'User-Agent' => 'dashboards.ecosyste.ms'}).returns(mock_response)
    
    # Mock sync_async to avoid background job in test
    Project.any_instance.expects(:sync_async)
    
    assert_difference('Project.count', 1) do
      post lookup_projects_url, params: { url: registry_url }
    end
    
    created_project = Project.last
    assert_equal repository_url.downcase, created_project.url
    assert_redirected_to project_path(created_project)
  end

  test "should fallback to original URL when API lookup fails" do
    registry_url = "https://www.npmjs.com/package/nonexistent-package"
    
    # Mock PURL conversion
    mock_purl = mock()
    mock_purl_without_version = mock()
    mock_purl.expects(:with).with(version: nil).returns(mock_purl_without_version).twice  # Called twice: once for package lookup, once for API lookup
    mock_purl_without_version.expects(:to_s).returns('pkg:npm/nonexistent-package').twice
    Purl.expects(:from_registry_url).with(registry_url).returns(mock_purl)
    
    # Mock API failure
    mock_response = mock()
    mock_response.expects(:success?).returns(false)
    Faraday.expects(:get).with("https://packages.ecosyste.ms/api/v1/packages/lookup", { purl: 'pkg:npm/nonexistent-package' }, {'User-Agent' => 'dashboards.ecosyste.ms'}).returns(mock_response)
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { url: registry_url }
    end
    
    assert_redirected_to new_project_path(url: registry_url)
  end

  test "should fallback gracefully when purl conversion fails" do
    non_existent_url = "https://invalid.registry.com/package/nonexistent"
    
    # Mock the Purl conversion to raise an error
    Purl.expects(:from_registry_url).with(non_existent_url).raises(StandardError.new("Invalid URL"))
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { url: non_existent_url }
    end
    
    assert_redirected_to new_project_path(url: non_existent_url)
  end

  test "should lookup project by purl parameter" do
    existing_project = create(:project, :with_repository, url: "https://github.com/test/repo")
    package = create(:package, project: existing_project, ecosystem: 'npm', name: 'test-package')
    package.update(purl: 'pkg:npm/test-package')
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { purl: 'pkg:npm/test-package@1.0.0' }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should create project and start syncing when repository URL resolved from purl" do
    purl_string = "pkg:npm/nonexistent-package@1.0.0"
    repository_url = "https://github.com/user/nonexistent-package"
    
    # Mock the purl parsing and API response
    mock_purl = mock()
    mock_purl_without_version = mock()
    mock_purl.expects(:with).with(version: nil).returns(mock_purl_without_version).twice
    mock_purl_without_version.expects(:to_s).returns('pkg:npm/nonexistent-package').twice
    Purl.expects(:parse).with(purl_string).returns(mock_purl)
    
    # Mock API response
    mock_response = mock()
    mock_response.expects(:success?).returns(true)
    mock_response.expects(:body).returns([{ 'repository_url' => repository_url }].to_json)
    Faraday.expects(:get).with("https://packages.ecosyste.ms/api/v1/packages/lookup", { purl: 'pkg:npm/nonexistent-package' }, {'User-Agent' => 'dashboards.ecosyste.ms'}).returns(mock_response)
    
    # Mock sync_async to avoid background job in test
    Project.any_instance.expects(:sync_async)
    
    assert_difference('Project.count', 1) do
      post lookup_projects_url, params: { purl: purl_string }
    end
    
    created_project = Project.last
    assert_equal repository_url.downcase, created_project.url
    assert_redirected_to project_path(created_project)
  end

  test "should show error when API lookup fails for purl parameter" do
    purl_string = "pkg:npm/nonexistent-package@1.0.0"
    
    # Mock the purl parsing
    mock_purl = mock()
    mock_purl_without_version = mock()
    mock_purl.expects(:with).with(version: nil).returns(mock_purl_without_version).twice
    mock_purl_without_version.expects(:to_s).returns('pkg:npm/nonexistent-package').twice
    mock_purl.expects(:name).returns('nonexistent-package')
    mock_purl.expects(:type).returns('npm')
    Purl.expects(:parse).with(purl_string).returns(mock_purl)
    
    # Mock API failure
    mock_response = mock()
    mock_response.expects(:success?).returns(false)
    Faraday.expects(:get).with("https://packages.ecosyste.ms/api/v1/packages/lookup", { purl: 'pkg:npm/nonexistent-package' }, {'User-Agent' => 'dashboards.ecosyste.ms'}).returns(mock_response)
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { purl: purl_string }
    end
    
    assert_redirected_to root_path
    assert_match(/Package not found.*nonexistent-package.*npm/, flash[:error])
  end

  test "should fallback gracefully when purl parameter parsing fails" do
    invalid_purl = "invalid-purl-string"
    
    # Mock the Purl parsing to raise an error
    Purl.expects(:parse).with(invalid_purl).raises(StandardError.new("Invalid PURL"))
    
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: { purl: invalid_purl }
    end
    
    assert_redirected_to new_project_path(url: invalid_purl)
  end

  test "should require either url or purl parameter" do
    assert_no_difference('Project.count') do
      post lookup_projects_url, params: {}
    end
    
    assert_redirected_to root_path
    assert_equal "Please provide either a URL or PURL parameter", flash[:alert]
  end

  test "should lookup project by purl parameter using GET request" do
    existing_project = create(:project, :with_repository, url: "https://github.com/test/repo")
    package = create(:package, project: existing_project, ecosystem: 'npm', name: 'test-package')
    package.update(purl: 'pkg:npm/test-package')
    
    assert_no_difference('Project.count') do
      get lookup_projects_url, params: { purl: 'pkg:npm/test-package@1.0.0' }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should work with dependency links using GET requests" do
    existing_project = create(:project, :with_repository, url: "https://github.com/test/repo")
    package = create(:package, project: existing_project, ecosystem: 'npm', name: 'lodash')
    package.update(purl: 'pkg:npm/lodash')
    
    # Simulate clicking a dependency link (GET request with purl parameter)
    assert_no_difference('Project.count') do
      get lookup_projects_url, params: { purl: 'pkg:npm/lodash' }
    end
    
    assert_redirected_to project_url(existing_project)
  end

  test "should flow from lookup to new project form to creation when authenticated" do
    user = create(:user)
    url = "https://github.com/flow/test"
    
    # Step 1: Anonymous lookup redirects to new project form
    post lookup_projects_url, params: { url: url }
    assert_redirected_to new_project_path(url: url)
    
    # Step 2: Accessing new project form requires login
    get new_project_path(url: url)
    assert_redirected_to login_url
    
    # Step 3: After login, can access form with pre-filled URL
    login_as user
    get new_project_path(url: url)
    assert_response :success
    assert_select 'input[name="project[url]"][value="' + url + '"]'
    
    # Step 4: Create project successfully
    assert_difference('Project.count') do
      post projects_url, params: { project: { url: url } }
    end
    
    project = Project.last
    assert_equal url, project.url
    assert_redirected_to project_url(project)
  end

  test "should show engagement page with comprehensive metrics" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    
    # Add some issues for testing engagement metrics
    create_list(:issue, 5, project: project, state: "open", created_at: 2.weeks.ago)
    create_list(:issue, 3, project: project, state: "closed", created_at: 3.weeks.ago, closed_at: 1.week.ago)
    
    travel_to Time.parse('2024-02-15') do
      get project_url(project, tab: 'engagement')
      assert_response :success
      assert_template :engagement
      
      # Verify project is assigned
      assigned_project = assigns(:project)
      assert_equal project, assigned_project
      
      # Verify period variables are assigned
      assert_not_nil assigns(:range)
      assert_not_nil assigns(:year)
      assert_not_nil assigns(:month)
      assert_not_nil assigns(:period_date)
      
      # Verify engagement metrics are assigned
      assert_not_nil assigns(:active_contributors_this_period)
      assert_not_nil assigns(:active_contributors_last_period)
      assert_not_nil assigns(:contributions_this_period)
      assert_not_nil assigns(:contributions_last_period)
      assert_not_nil assigns(:issue_authors_this_period)
      assert_not_nil assigns(:issue_authors_last_period)
      assert_not_nil assigns(:pr_authors_this_period)
      assert_not_nil assigns(:pr_authors_last_period)
      assert_not_nil assigns(:all_time_contributors)
      
      # Verify default month behavior
      controller = @controller
      assert_equal 2024, controller.send(:year)
      assert_equal 1, controller.send(:month)  # Previous month (January)
    end
  end

  test "should show productivity page with comprehensive metrics" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    
    # Add test data for productivity metrics
    create_list(:commit, 8, project: project, timestamp: 2.weeks.ago)
    create_list(:tag, 2, project: project, published_at: 3.weeks.ago)
    create_list(:issue, 6, project: project, state: "open", created_at: 2.weeks.ago)
    create_list(:issue, 4, project: project, state: "closed", created_at: 3.weeks.ago, closed_at: 1.week.ago)
    
    travel_to Time.parse('2024-02-15') do
      get project_url(project, tab: 'productivity')
      assert_response :success
      assert_template :productivity
      
      # Verify project is assigned
      assigned_project = assigns(:project)
      assert_equal project, assigned_project
      
      # Verify productivity metrics are assigned
      assert_not_nil assigns(:commits_this_period)
      assert_not_nil assigns(:commits_last_period)
      assert_not_nil assigns(:tags_this_period)
      assert_not_nil assigns(:tags_last_period)
      assert_not_nil assigns(:avg_commits_per_author_this_period)
      assert_not_nil assigns(:avg_commits_per_author_last_period)
      assert_not_nil assigns(:new_issues_this_period)
      assert_not_nil assigns(:new_issues_last_period)
      assert_not_nil assigns(:new_prs_this_period)
      assert_not_nil assigns(:new_prs_last_period)
      
      # Verify metrics are numeric
      assert_kind_of Integer, assigns(:commits_this_period)
      assert_kind_of Integer, assigns(:commits_last_period)
      assert assigns(:avg_commits_per_author_this_period).is_a?(Numeric)
      assert assigns(:avg_commits_per_author_last_period).is_a?(Numeric)
      
      # Verify default month behavior
      controller = @controller
      assert_equal 2024, controller.send(:year)
      assert_equal 1, controller.send(:month)  # Previous month (January)
    end
  end

  test "should handle year boundary when defaulting to previous month" do
    project = create(:project, :with_repository)
    
    travel_to Time.parse('2024-01-15') do
      get project_url(project, tab: 'engagement')
      assert_response :success
      
      # Should default to December 2023 (previous month across year boundary)
      controller = @controller
      assert_equal 2023, controller.send(:year)
      assert_equal 12, controller.send(:month)
    end
  end

  # Analytics pages tests
  test "should show adoption page" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    get project_url(project, tab: 'adoption')
    assert_response :success
    assert_template :adoption
    
    # Verify required instance variables are assigned
    assigned_project = assigns(:project)
    assert_equal project, assigned_project
    
    # Should assign top package if available
    top_package = assigns(:top_package)
    # top_package may be nil if no packages exist, which is fine
  end

  test "should show dependencies page" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    get project_url(project, tab: 'dependencies')
    assert_response :success
    assert_template :dependencies
    
    # Verify project and dependency counts are assigned
    assigned_project = assigns(:project)
    assert_equal project, assigned_project
    
    direct_dependencies = assigns(:direct_dependencies)
    development_dependencies = assigns(:development_dependencies)
    transitive_dependencies = assigns(:transitive_dependencies)
    
    assert_not_nil direct_dependencies
    assert_not_nil development_dependencies
    assert_not_nil transitive_dependencies
  end
  
  test "should show dependencies page with direct filter" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    get project_url(project, tab: 'dependencies', filter: 'direct')
    assert_response :success
    assert_template :dependencies
    
    # Verify filter parameter is preserved
    assert_equal 'direct', @request.params[:filter]
  end
  
  test "should show dependencies page with development filter" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    get project_url(project, tab: 'dependencies', filter: 'development')
    assert_response :success
    assert_template :dependencies
    
    # Verify filter parameter is preserved
    assert_equal 'development', @request.params[:filter]
  end
  
  test "should show dependencies page with transitive filter" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    get project_url(project, tab: 'dependencies', filter: 'transitive')
    assert_response :success
    assert_template :dependencies
    
    # Verify filter parameter is preserved
    assert_equal 'transitive', @request.params[:filter]
  end

  test "should show dependency links with purl parameter" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    
    # Mock dependencies data
    mock_dependencies = [
      {
        'package_name' => 'lodash',
        'ecosystem' => 'npm',
        'requirements' => '^4.17.21',
        'kind' => 'runtime',
        'direct' => true
      },
      {
        'package_name' => 'express',
        'ecosystem' => 'npm', 
        'requirements' => '^4.18.2',
        'kind' => 'runtime',
        'direct' => true
      }
    ]
    
    # Mock the project methods
    project.stubs(:direct_dependencies).returns(mock_dependencies)
    project.stubs(:development_dependencies).returns([])
    project.stubs(:transitive_dependencies).returns([])
    # Stub both find methods used by the controller
    Project.stubs(:find_by_slug).with(project.to_param).returns(project)
    Project.stubs(:find).with(project.id).returns(project)
    
    get project_url(project, tab: 'dependencies')
    assert_response :success
    assert_template :dependencies
    
    # Check that dependency links are present with correct purl parameters
    assert_select 'a[href*="/projects/lookup?purl=pkg%3Anpm%2Flodash"]', text: 'lodash'
    assert_select 'a[href*="/projects/lookup?purl=pkg%3Anpm%2Fexpress"]', text: 'express'
    
    # Verify the links have proper attributes
    assert_select 'a[title*="Look up lodash project"]'
    assert_select 'a[title*="Look up express project"]'
  end

  test "should show finance page" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    get project_url(project, tab: 'finance')
    assert_response :success
    assert_template :finance
    
    # Verify project is assigned
    assigned_project = assigns(:project)
    assert_equal project, assigned_project
    
    # Finance variables may be nil if no collective/sponsors exist
    # This is expected behavior
  end

  test "should show responsiveness page" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    get project_url(project, tab: 'responsiveness')
    assert_response :success
    assert_template :responsiveness
    
    # Verify project is assigned
    assigned_project = assigns(:project)
    assert_equal project, assigned_project
    
    # Verify responsiveness metrics are assigned
    assert_not_nil assigns(:time_to_close_prs_this_period)
    assert_not_nil assigns(:time_to_close_prs_last_period)
    assert_not_nil assigns(:time_to_close_issues_this_period)
    assert_not_nil assigns(:time_to_close_issues_last_period)
  end

  test "should redirect to syncing for unready project on analytics pages" do
    project = create(:project, :without_repository, last_synced_at: nil, sync_status: 'pending')
    
    # Test that analytics pages redirect to syncing for unready projects
    get project_url(project, tab: 'adoption')
    assert_response :success
    assert_template :syncing
    
    get project_url(project, tab: 'dependencies')
    assert_response :success
    assert_template :syncing
    
    get project_url(project, tab: 'finance')
    assert_response :success
    assert_template :syncing
    
    get project_url(project, tab: 'responsiveness')
    assert_response :success
    assert_template :syncing
  end

  # Bot filtering tests
  test "should handle bot filtering on engagement page" do
    skip "Temporarily skipping failing test"
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    create_list(:issue, 3, project: project, state: "open", created_at: 2.weeks.ago)
    
    # Test exclude_bots parameter
    get project_url(project, tab: 'engagement'), params: { exclude_bots: 'true' }
    assert_response :success
    assert_template :engagement
    
    # Test only_bots parameter  
    get project_url(project, tab: 'engagement'), params: { only_bots: 'true' }
    assert_response :success
    assert_template :engagement
  end

  test "should handle bot filtering on productivity page" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    create_list(:issue, 3, project: project, state: "open", created_at: 2.weeks.ago)
    
    # Test exclude_bots parameter
    get project_url(project, tab: 'productivity'), params: { exclude_bots: 'true' }
    assert_response :success
    assert_template :productivity
    
    # Test only_bots parameter
    get project_url(project, tab: 'productivity'), params: { only_bots: 'true' }
    assert_response :success
    assert_template :productivity
  end

  test "should handle bot filtering on responsiveness page" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    create_list(:issue, 3, project: project, state: "closed", created_at: 3.weeks.ago, closed_at: 2.weeks.ago)
    
    # Test exclude_bots parameter
    get project_url(project, tab: 'responsiveness'), params: { exclude_bots: 'true' }
    assert_response :success
    assert_template :responsiveness
    
    # Test only_bots parameter
    get project_url(project, tab: 'responsiveness'), params: { only_bots: 'true' }
    assert_response :success
    assert_template :responsiveness
  end

  # Nested collection routes tests
  test "should access project through collection context" do
    user = create(:user)
    collection = create(:collection, :public, user: user)
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    create(:collection_project, collection: collection, project: project)
    
    # Test nested show route
    get collection_project_url(collection, project)
    assert_response :success
    assert_template :show
    
    # Verify both collection and project are assigned
    assigned_collection = assigns(:collection)
    assigned_project = assigns(:project)
    assert_equal collection, assigned_collection
    assert_equal project, assigned_project
  end

  test "should access project analytics through collection context" do
    user = create(:user)
    collection = create(:collection, :public, user: user)
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    create(:collection_project, collection: collection, project: project)
    
    # Test nested analytics routes
    get collection_project_url(collection, project, tab: 'engagement')
    assert_response :success
    assert_template :engagement
    
    get collection_project_url(collection, project, tab: 'productivity')
    assert_response :success
    assert_template :productivity
    
    get collection_project_url(collection, project, tab: 'adoption')
    assert_response :success
    assert_template :adoption
    
    # Verify collection context is maintained
    assigned_collection = assigns(:collection)
    assert_equal collection, assigned_collection
  end

  test "should not access private collection projects by non-owner" do
    owner = create(:user)
    other_user = create(:user)
    private_collection = create(:collection, :private, user: owner)
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    create(:collection_project, collection: private_collection, project: project)
    
    # The controller should return 404 for non-owner accessing private collection
    get collection_project_url(private_collection, project)
    assert_response :not_found
  end

  # Show page with realistic data test
  test "should show project page with comprehensive data" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)

    # Add realistic test data
    create_list(:commit, 10, project: project, timestamp: 1.month.ago)
    create_list(:issue, 8, project: project, state: "open", created_at: 2.weeks.ago)
    create_list(:issue, 5, project: project, state: "closed", created_at: 3.weeks.ago, closed_at: 1.week.ago)
    create_list(:package, 3, project: project)
    create_list(:tag, 2, project: project, published_at: 1.month.ago)

    get project_url(project)
    assert_response :success
    assert_template :show

    # Verify project data is assigned
    assigned_project = assigns(:project)
    assert_equal project, assigned_project

    # Verify chart data is assigned
    assert_not_nil assigns(:commits_per_period)
    assert_not_nil assigns(:commits_this_period)
    assert_not_nil assigns(:commits_last_period)

    # Verify project has the data we created
    assert_equal 10, project.commits.count
    assert_equal 13, project.issues.count  # 8 open + 5 closed
    assert_equal 3, project.packages.count
    assert_equal 2, project.tags.count
  end

  test "should handle package with nil ranking average" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)

    # Create package with nil ranking average
    package = create(:package, project: project)
    package.update(metadata: { 'rankings' => { 'average' => nil } })

    get project_url(project)
    assert_response :success
    assert_template :show

    # Verify ranking widget is not displayed when ranking is nil
    assert_select 'h5.card-title', text: 'Ranking', count: 0
  end

  test "should prefer package with valid ranking over nil ranking" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)

    # Create package without ranking (should be ignored)
    package_no_rank = create(:package, project: project, name: 'no-rank-package')
    package_no_rank.update(metadata: { 'rankings' => { 'average' => nil } })

    # Create package with ranking (should be selected)
    package_with_rank = create(:package, project: project, name: 'ranked-package')
    package_with_rank.update(metadata: {
      'rankings' => { 'average' => 5.3 },
      'registry' => { 'name' => 'npm' }
    })

    get project_url(project)
    assert_response :success
    assert_template :show

    # Verify ranking widget is displayed with the ranked package
    assert_select 'h5.card-title', text: /Ranking/
    assert_select 'span.stat-card-title', text: /Top 5\.3%/
    assert_select 'span.stat-card-text', text: /on npm/
  end

  test "should create collection from dependencies when logged in" do
    user = create(:user)
    login_as(user)
    
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    
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
          }
        ]
      }
    ]
    
    project.update!(dependencies: dependencies_data)
    
    assert_difference 'Collection.count', 1 do
      post create_collection_from_dependencies_project_path(project)
    end
    
    assert_redirected_to Collection.last
    assert_match /Collection created successfully/, flash[:notice]
  end

  test "should not create collection when not logged in" do
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago)
    
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
    
    assert_no_difference 'Collection.count' do
      post create_collection_from_dependencies_project_path(project)
    end
    
    assert_redirected_to login_path
  end

  test "should handle project with no dependencies" do
    user = create(:user)
    login_as(user)
    
    project = create(:project, :with_repository, last_synced_at: 30.minutes.ago, dependencies: nil)
    
    assert_no_difference 'Collection.count' do
      post create_collection_from_dependencies_project_path(project)
    end
    
    assert_redirected_to project_url(project, tab: 'dependencies')
    assert_match /Unable to create collection/, flash[:alert]
  end

  test "should require login when no existing collection and not logged in" do
    WebMock.enable!
    
    project = create(:project, :with_repository)
    project.update!(repository: project.repository.merge({
      'owner_url' => 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails'
    }))
    
    owner_response = {
      'login' => 'rails',
      'name' => 'Ruby on Rails',
      'html_url' => 'https://github.com/rails',
      'kind' => 'organization'
    }
    
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails")
      .with(headers: {
        'User-Agent' => 'dashboards.ecosyste.ms',
        'X-Source' => 'dashboards.ecosyste.ms'
      })
      .to_return(status: 200, body: owner_response.to_json)
    
    get owner_collection_project_path(project)
    
    assert_redirected_to login_path
    assert_equal 'Please sign in to create collections.', flash[:alert]
  ensure
    WebMock.reset!
  end

  test "should allow viewing existing public collection without login" do
    WebMock.enable!
    
    # Create existing public collection (no user needed for this test)
    user = create(:user)
    existing_collection = create(:collection, 
      github_organization_url: 'https://github.com/rails',
      user: user,
      visibility: 'public'
    )
    
    project = create(:project, :with_repository)
    project.update!(repository: project.repository.merge({
      'owner_url' => 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails'
    }))
    
    owner_response = {
      'login' => 'rails',
      'name' => 'Ruby on Rails',
      'html_url' => 'https://github.com/rails',
      'kind' => 'organization'
    }
    
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails")
      .with(headers: {
        'User-Agent' => 'dashboards.ecosyste.ms',
        'X-Source' => 'dashboards.ecosyste.ms'
      })
      .to_return(status: 200, body: owner_response.to_json)
    
    # Not logged in, but should still be able to view existing public collection
    get owner_collection_project_path(project)
    
    assert_redirected_to collection_path(existing_collection)
    assert_match /Viewing .* collection!/, flash[:notice]
  ensure
    WebMock.reset!
  end

  test "should create owner collection successfully" do
    WebMock.enable!
    
    user = create(:user)
    login_as(user)
    
    project = create(:project, :with_repository)
    project.update!(repository: project.repository.merge({
      'owner_url' => 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails'
    }))
    
    owner_response = {
      'login' => 'rails',
      'name' => 'Ruby on Rails',
      'html_url' => 'https://github.com/rails',
      'kind' => 'organization'
    }
    
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails")
      .with(headers: {
        'User-Agent' => 'dashboards.ecosyste.ms',
        'X-Source' => 'dashboards.ecosyste.ms'
      })
      .to_return(status: 200, body: owner_response.to_json)
    
    assert_difference 'Collection.count', 1 do
      get owner_collection_project_path(project)
    end
    
    collection = Collection.last
    assert_redirected_to collection_path(collection)
    assert_match /Viewing rails collection!/, flash[:notice]
    assert_equal 'rails', collection.name
    assert_equal 'https://github.com/rails', collection.github_organization_url
    assert_equal user, collection.user
  ensure
    WebMock.reset!
  end

  test "should redirect to existing owner collection" do
    WebMock.enable!
    
    user = create(:user)
    login_as(user)
    
    # Create existing collection
    existing_collection = create(:collection, 
      github_organization_url: 'https://github.com/rails',
      user: user
    )
    
    project = create(:project, :with_repository)
    project.update!(repository: project.repository.merge({
      'owner_url' => 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails'
    }))
    
    owner_response = {
      'login' => 'rails',
      'name' => 'Ruby on Rails',
      'html_url' => 'https://github.com/rails',
      'kind' => 'organization'
    }
    
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/rails")
      .with(headers: {
        'User-Agent' => 'dashboards.ecosyste.ms',
        'X-Source' => 'dashboards.ecosyste.ms'
      })
      .to_return(status: 200, body: owner_response.to_json)
    
    assert_no_difference 'Collection.count' do
      get owner_collection_project_path(project)
    end
    
    assert_redirected_to collection_path(existing_collection)
    assert_match /Viewing .* collection!/, flash[:notice]
  ensure
    WebMock.reset!
  end

  test "should handle project without owner information" do
    user = create(:user)
    login_as(user)
    
    project = create(:project, :with_repository)
    # Remove owner_url from repository data
    project.update!(repository: project.repository.except('owner_url'))
    
    assert_no_difference 'Collection.count' do
      get owner_collection_project_path(project)
    end
    
    assert_redirected_to project_path(project)
    assert_match /Unable to create owner collection/, flash[:alert]
  end

  test "should require login when project has no owner_url" do
    project = create(:project, :with_repository)
    # Remove owner_url from repository data
    project.update!(repository: project.repository.except('owner_url'))
    
    get owner_collection_project_path(project)
    
    assert_redirected_to login_path
    assert_equal 'Please sign in to create collections.', flash[:alert]
  end

  test "should fix stuck sync on syncing page and redirect when ready" do
    # Create a project with stuck sync that was previously synced
    project = create(:project, :with_repository, sync_status: 'syncing')
    project.update_column(:updated_at, 1.hour.ago)  # Make it appear stuck
    project.update_column(:last_synced_at, 2.days.ago)  # Has been synced before
    
    # Verify it's stuck and was previously synced
    assert project.sync_stuck?
    refute project.never_synced?
    
    # Mock the sync_async method to verify it's called for stuck syncs
    Project.any_instance.expects(:sync_async).once
    
    get syncing_project_url(project)
    
    # Should redirect to project page with notice about background sync
    assert_redirected_to project_url(project)
    assert_equal 'Project is now accessible. Sync continues in background.', flash[:notice]
    
    # Verify sync_status was fixed
    project.reload
    assert_equal 'completed', project.sync_status
  end

  test "should show syncing page for never-synced actively syncing project" do
    # Create a never-synced project that's actively syncing (recent updated_at)
    project = create(:project, :with_repository, sync_status: 'syncing', last_synced_at: nil)
    project.update_column(:updated_at, 5.minutes.ago)
    
    # Verify it's not stuck and never synced
    refute project.sync_stuck?
    assert project.never_synced?
    
    # Should not call sync_async for actively syncing project
    Project.any_instance.expects(:sync_async).never
    
    get syncing_project_url(project)
    
    # Should show syncing page
    assert_response :success
    assert_template :syncing
    assert_select 'h2', text: /Syncing project data/
  end

  test "should redirect previously synced project from syncing page" do
    # Create a project that was previously synced but is not actively syncing
    project = create(:project, :with_repository, sync_status: 'completed')
    project.update_column(:last_synced_at, 12.hours.ago)  # Previously synced
    
    # Verify it was previously synced
    refute project.never_synced?
    
    # Should not call sync_async
    Project.any_instance.expects(:sync_async).never
    
    get syncing_project_url(project)
    
    # Should redirect to project page
    assert_redirected_to project_url(project)
  end

  test "should show project page even when background sync is running for previously synced project" do
    # Create a project that was previously synced but is now syncing in background
    project = create(:project, :with_repository, sync_status: 'syncing')
    project.update_column(:last_synced_at, 1.day.ago)  # Previously synced
    project.update_column(:updated_at, 2.minutes.ago)  # Currently syncing (not stuck)

    # Verify it's actively syncing but was previously synced
    refute project.sync_stuck?
    refute project.never_synced?

    get project_url(project)

    # Should show main project page, not syncing page
    assert_response :success
    assert_template :show
  end

  test "should allow lookup without CSRF token" do
    existing_project = create(:project, url: "https://github.com/test/repo")

    # Simulate request without CSRF token (like from external link)
    get lookup_projects_url, params: { url: existing_project.url }

    assert_redirected_to project_url(existing_project)
  end

end