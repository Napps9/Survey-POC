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
    assert_includes response.body, '"playverto-v38"'
  end

  test "cross-origin images are network-first, so a bad fetch can't be pinned" do
    get pwa_service_worker_path(format: :js)
    assert_response :success

    # An opaque response is indistinguishable from a 404 or a rate limit, so
    # answering from cache first is how a deck of Pexels card photos goes
    # permanently grey: one bad fetch is stored as though it were the photo, and
    # the background revalidate can't tell the replacement is bad either.
    assert_includes response.body, "const sameOrigin = new URL(req.url).origin === self.location.origin"
    assert_match(/Cross-origin: the network is the only source/, response.body)
  end

  test "the image strategy never answers with a network error" do
    get pwa_service_worker_path(format: :js)
    assert_response :success

    # caches.open and cache.put both reject in ordinary conditions — quota, or
    # storage being unavailable in a partitioned third-party frame, which is
    # exactly what embedding a Verto in another page creates. Neither may take
    # the image request down with it, so every path ends at the plain network.
    strategy = response.body[/async function imageCache.*?\n\}/m]
    assert strategy, "expected to find the imageCache strategy in the worker"
    assert_not_includes strategy, "Response.error()"
  end

  test "media and ranged requests are never intercepted" do
    get pwa_service_worker_path(format: :js)
    assert_response :success

    # A <video> asks for byte ranges. Answered out of the worker, a cross-origin
    # clip comes back opaque — no 206, no Content-Range — and the element errors
    # instead of playing, leaving a card's left panel painting nothing at all.
    assert_includes response.body,
      'if (req.destination === "video" || req.destination === "audio" || req.headers.has("range")) return'
  end

  test "player HTML strategy stays network-first, not stale-while-revalidate" do
    get pwa_service_worker_path(format: :js)
    assert_response :success
    assert_includes response.body, "networkFirstWithTimeout(event, req, PAGE_CACHE)"
    refute_includes response.body, "staleWhileRevalidate"
  end
end
