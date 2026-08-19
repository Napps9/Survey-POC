require "test_helper"

# See config/initializers/static_html_cache_control.rb — without an explicit
# Cache-Control, a static page updates invisibly behind a browser's heuristic
# cache until someone hard-refreshes.
class StaticHtmlCacheControlTest < ActionDispatch::IntegrationTest
  def cache_control
    response.headers["cache-control"] || response.headers["Cache-Control"]
  end

  # The middleware matches on the .html suffix rather than on a filename, so a
  # new one-pager is covered the moment it lands in public/. Both are asserted
  # anyway: that's the property worth pinning, and it costs two requests.
  %w[ /vertonow.html /verto-for-research.html ].each do |path|
    test "#{path} revalidates, so an updated page can't hide behind a heuristic cache" do
      get path
      assert_response :success

      assert_equal StaticHtmlCacheControl::CACHE_CONTROL, cache_control,
        "the one-pager must revalidate — it's edited in place, and a stale copy has no other way out"
    end
  end

  test "non-HTML public files keep the app's own caching" do
    get "/robots.txt"
    assert_response :success

    # test.rb sets public_file_server.headers to a one-hour cache; the middleware
    # must leave everything that isn't HTML exactly as it found it, so
    # fingerprinted assets keep caching hard.
    assert_not_equal StaticHtmlCacheControl::CACHE_CONTROL, cache_control
  end
end
