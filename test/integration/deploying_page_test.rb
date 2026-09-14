require "test_helper"

# The page shown while a deploy replaces the running instance, in place of
# Render's "502 Bad Gateway". The persistent disk pins the service to one
# instance, so every deploy is a stop/start and Render's edge answers for the
# app until the new instance passes /up (render.yaml, DEPLOYMENT_RUNBOOK §8).
#
# Two consumers, tested separately: the player's service worker inlines it
# (ServiceWorkerTest), and Render's maintenance mode can be pointed at a copy
# hosted off the service. Both need the page to stand entirely on its own.
class DeployingPageTest < ActionDispatch::IntegrationTest
  def page
    File.read(Rails.root.join("public", "deploying.html"))
  end

  test "is branded, not Render's black-and-white gateway page" do
    html = page
    assert_includes html, ">play<"
    assert_includes html, ">verto<"
    assert_includes html, "#1C2034", "should use the brand background"
    # The source comments explain what a 502 is; the visitor never reads one.
    visible = Nokogiri::HTML(html).tap { |doc| doc.css("script, style").remove }.at("body").text
    assert_no_match(/bad gateway|502/i, visible)
  end

  test "says what is happening in the owner's words" do
    assert_match(/deploying a new feature/i, page)
    assert_match(/back in a few minutes/i, page)
  end

  test "requests nothing from a host that may be the thing that's down" do
    html = page
    assert_not_includes html, "<link",   "must not link a stylesheet"
    assert_not_includes html, "<img",    "must not request an image"
    assert_not_includes html, "src=",    "must not load an external script or image"
    assert_not_includes html, "http://", "must not reference a remote host"
    assert_not_includes html, "https://", "must not reference a remote host"
  end

  test "polls the health check and reloads itself when the app is back" do
    html = page
    # The one script the page carries. /up is what Render's own health check
    # polls, and Render answers for a down app with a 502/503, never a 200 —
    # so `ok` means the app itself replied. `no-store` keeps a browser cache
    # from answering the poll; the worker passes /up through for the same
    # reason (ServiceWorkerTest).
    assert_includes html, 'fetch("/up", { cache: "no-store"'
    assert_includes html, "if (res.ok) window.location.reload()"
    # And a manual way out, plus a plain refresh for a browser with no JS.
    assert_includes html, 'id="retry"'
    assert_includes html, '<noscript><meta http-equiv="refresh"'
  end

  test "backs off rather than hammering the instance the second it boots" do
    html = page
    assert_includes html, "delay = Math.min(delay * 1.5, 30000)"
    assert_includes html, "Math.random()"
  end

  test "is not indexed" do
    assert_includes page, '<meta name="robots" content="noindex">'
  end

  # ── The scene ──────────────────────────────────────────────────────────
  # A crane stacking a building behind a theatre curtain, because a minute of
  # downtime is a better moment to be charming than to be terse. It is one
  # inline SVG driven by CSS keyframes: nothing to fetch, which is the whole
  # constraint this page lives under.

  test "the scene is decorative, so a screen reader reads the copy and not the set" do
    assert_includes page, '<div class="stage" aria-hidden="true">'
  end

  test "every part of the scene shares one loop period" do
    # The floors, the crane's trolley and cable, the curtain, the star, the
    # footlights and the glow are separate animations that have to agree about
    # where they are: the hook is only ever on the block it is carrying because
    # its keyframes are that block's beat written out absolutely. A second
    # period anywhere and they drift apart within a few loops.
    periods = page.scan(/animation:[^;]*?(\d+(?:\.\d+)?)s/).flatten.uniq
    assert_equal [ "11" ], periods, "every animation should run on the same 11s loop"
  end

  test "each floor is staggered off the shared keyframes rather than its own" do
    html = page
    assert_includes html, "animation-delay: calc(var(--i) * .8s)"
    # And hidden until its own beat, and again from the moment the curtain is
    # shut — otherwise the loop's reset (six floors vanishing) happens in full
    # view and the scene visibly jumps every time round.
    (0..5).each { |i| assert_match(/@keyframes v#{i} .*visibility: hidden/, html) }
  end

  test "reduced motion stops the scene and leaves the finished building" do
    html = page
    assert_match(/@media \(prefers-reduced-motion: reduce\) \{\s*\.stage \* \{ animation: none !important; \}/, html)
    # This only works because every un-animated base state IS the finished
    # scene. The crane's cable is the one that needs saying: its base length
    # parks the hook at stage level, and a bare value here left it dangling in
    # mid-air beside the building.
    assert_includes html, "transform: scaleY(81); animation: cb 11s infinite"
  end

  test "the scene stops repainting once the poller has given up" do
    html = page
    # Half an hour in a tab nobody is watching, the page stops asking whether
    # the app is back; it should stop animating a pattern-filled curtain too.
    assert_includes html, ".still .stage * { animation-play-state: paused; }"
    assert_includes html, 'document.body.className += " still"'
  end

  test "the one tap target is big enough to hit" do
    assert_includes page, "padding: 14px 26px", "the retry button should clear 44px"
  end

  test "is served from public/ with the revalidating cache policy static HTML gets" do
    get "/deploying.html"
    assert_response :success
    assert_match %r{\Atext/html}, response.content_type
    assert_equal StaticHtmlCacheControl::CACHE_CONTROL, response.headers["cache-control"]
  end
end
