require "test_helper"

# The service worker is plain JS the test suite can't execute, but its two
# load-bearing properties are greppable: the player HTML must stay
# network-first (stale-while-revalidate is what pinned respondents on stale
# Vertos until a hard refresh), and CACHE_VERSION must move when the worker's
# own behaviour changes. Pinning both here makes an accidental revert fail
# loudly instead of shipping silently.
class ServiceWorkerTest < ActionDispatch::IntegrationTest
  test "service worker is served as JS with the current cache version" do
    get pwa_service_worker_path(format: :js)
    assert_response :success
    assert_match %r{\Atext/javascript}, response.content_type
    assert_includes response.body, '"playverto-v36"'
  end

  test "player HTML strategy stays network-first, not stale-while-revalidate" do
    get pwa_service_worker_path(format: :js)
    assert_response :success
    assert_includes response.body, "networkFirstWithTimeout(event, req, PAGE_CACHE)"
    refute_includes response.body, "staleWhileRevalidate"
  end
end
