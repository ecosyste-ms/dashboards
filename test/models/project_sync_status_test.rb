require "test_helper"

class ProjectSyncStatusTest < ActiveSupport::TestCase
  setup do
    # Use unique URL to avoid conflicts
    @project = create(:project, url: "https://github.com/test/sync-status-#{SecureRandom.hex(8)}", 
                       repository: {
                         "full_name" => "test/sync-status",
                         "name" => "sync-status",
                         "owner" => "test"
                       })
  end

  test "sync methods update individual last_synced_at timestamps" do
    # Mock the external API calls for commits
    stub_request(:get, @project.commits_api_url)
      .to_return(status: 200, body: {
        total_commits: 0,
        commits_url: "http://example.com/commits"
      }.to_json)
    
    stub_request(:get, /example\.com\/commits/)
      .to_return(status: 200, body: [].to_json)

    # Test commits sync updates commits_last_synced_at
    @project.sync_commits
    @project.reload
    assert_not_nil @project.commits_last_synced_at
    assert @project.commits_last_synced_at > 1.minute.ago

    # Test packages sync updates packages_last_synced_at  
    stub_request(:get, @project.packages_url)
      .to_return(status: 200, body: [].to_json)
    
    @project.fetch_packages
    @project.reload
    assert_not_nil @project.packages_last_synced_at
    assert @project.packages_last_synced_at > 1.minute.ago

    # Test dependencies sync updates dependencies_last_synced_at
    @project.repository = @project.repository.merge({ "manifests_url" => "http://example.com/manifests" })
    @project.save
    stub_request(:get, "http://example.com/manifests")
      .to_return(status: 200, body: [].to_json)
    
    @project.fetch_dependencies
    @project.reload
    assert_not_nil @project.dependencies_last_synced_at
    assert @project.dependencies_last_synced_at > 1.minute.ago
  end

  test "sync status view helpers display proper timestamps" do
    # Test when timestamps are nil
    assert_equal 'Never', sync_status_display(@project.commits_last_synced_at)
    assert_equal 'Never', sync_status_display(@project.packages_last_synced_at)
    assert_equal 'Never', sync_status_display(@project.dependencies_last_synced_at)

    # Test when timestamps are present
    time = 2.hours.ago
    @project.update(
      commits_last_synced_at: time,
      packages_last_synced_at: time,
      dependencies_last_synced_at: time
    )
    
    assert_match(/hours? ago/, sync_status_display(@project.commits_last_synced_at))
    assert_match(/hours? ago/, sync_status_display(@project.packages_last_synced_at))
    assert_match(/hours? ago/, sync_status_display(@project.dependencies_last_synced_at))
  end

  private

  def sync_status_display(timestamp)
    timestamp ? "#{time_ago_in_words(timestamp)} ago" : 'Never'
  end

  def time_ago_in_words(timestamp)
    ActionController::Base.helpers.time_ago_in_words(timestamp)
  end
end
