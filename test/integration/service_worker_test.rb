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
    assert_includes response.body, '"playverto-v40"'
  end

  test "the worker can reach the Pexels CDNs it refetches card art from" do
    get pwa_service_worker_path(format: :js)
    assert_response :success

    # A worker's own fetches are governed by the CSP delivered with THIS script
    # at install time, and the browser only reinstalls when the script's bytes
    # change. So connect-src has to allow Pexels on the very response that
    # carries the worker — otherwise imageCache is refused before it reaches the
    # network, which is what left every card panel blank.
    csp = response.headers["Content-Security-Policy"].to_s
    connect = csp.split(";").map(&:strip).find { |d| d.start_with?("connect-src") }

    assert connect, "the worker script should carry the app's CSP"
    assert_includes connect, "https://images.pexels.com"
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

  test "the cache-first strategy never answers with a network error either" do
    get pwa_service_worker_path(format: :js)
    assert_response :success

    # cacheFirst serves the Active Storage blobs — including the publishing
    # organisation's logo on the player's welcome and thank-you cards. It used
    # to answer Response.error() when a fetch failed, and an <img> handed a
    # network error paints the browser's broken-image glyph, so one flaky
    # request on a phone changing cells was enough to make a Verto look broken.
    # Same rule as imageCache above — every path ends at the plain network.
    strategy = response.body[/async function cacheFirst.*?\n\}/m]
    assert strategy, "expected to find the cacheFirst strategy in the worker"
    assert_not_includes strategy, "Response.error()"
  end

  test "cache-first writes are held open with waitUntil so they land on iOS" do
    get pwa_service_worker_path(format: :js)
    assert_response :success

    # WebKit kills an idle worker the moment it has answered, so a bare
    # `cache.put(...)` after the response is returned routinely never completes
    # — the exact hazard networkFirstWithTimeout and imageCache each already
    # guard against. Both call sites must pass `event` for the guard to work.
    strategy = response.body[/async function cacheFirst.*?\n\}/m]
    assert_includes strategy, "event?.waitUntil(cache.put("
    assert_includes response.body, "cacheFirst(req, IMAGE_CACHE, event)"
    assert_includes response.body, "cacheFirst(req, ASSET_CACHE, event)"
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
