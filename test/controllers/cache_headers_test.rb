require 'test_helper'

class CacheHeadersTest < ActionDispatch::IntegrationTest
  test "public HTML page sets cache headers with s-maxage" do
    project = create(:project, :with_repository)

    get project_url(project)
    assert_response :success

    cache_control = response.headers['Cache-Control']
    assert_match(/public/, cache_control)
    assert_match(/s-maxage=21600/, cache_control)
    assert_match(/max-age=300/, cache_control)
    assert_match(/stale-while-revalidate=21600/, cache_control)
    assert_match(/stale-if-error=86400/, cache_control)
  end

  test "public HTML page does not set cache headers when logged in" do
    user = create(:user)
    login_as(user)
    project = create(:project, :with_repository)

    get project_url(project)
    assert_response :success

    cache_control = response.headers['Cache-Control']
    assert_no_match(/s-maxage/, cache_control.to_s)
    assert_no_match(/public/, cache_control.to_s)
  end

  test "home page sets cache headers" do
    get root_url
    assert_response :success

    cache_control = response.headers['Cache-Control']
    assert_match(/s-maxage=21600/, cache_control)
  end

  test "API endpoint sets shorter s-maxage" do
    project = create(:project, url: "https://github.com/test/api-cache-#{SecureRandom.hex(4)}", repository: { "full_name" => "test/cache" })

    get api_v1_project_url(project), as: :json
    assert_response :success

    cache_control = response.headers['Cache-Control']
    assert_match(/s-maxage=3600/, cache_control)
    assert_match(/max-age=300/, cache_control)
  end

  test "API ping endpoint does not set cache headers" do
    project = create(:project, url: "https://github.com/test/api-ping-#{SecureRandom.hex(4)}", repository: { "full_name" => "test/ping" })
    Project.any_instance.expects(:sync_async)

    get ping_api_v1_project_url(project), as: :json
    assert_response :success

    cache_control = response.headers['Cache-Control'].to_s
    assert_no_match(/s-maxage/, cache_control)
  end

  test "sessions controller does not set cache headers" do
    get login_url
    assert_response :success

    cache_control = response.headers['Cache-Control'].to_s
    assert_no_match(/s-maxage/, cache_control)
  end

  test "projects#new does not set cache headers" do
    user = create(:user)
    login_as(user)

    get new_project_url
    assert_response :success

    cache_control = response.headers['Cache-Control'].to_s
    assert_no_match(/s-maxage/, cache_control)
  end
end
