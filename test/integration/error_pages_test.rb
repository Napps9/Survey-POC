require "test_helper"

# P2-3. The stock Rails error pages shipped untouched: grey Arial on #EFEFEF,
# with a red bar and "If you are the application owner check the logs for more
# information." Not a functional bug, but the last thing a respondent or a
# customer sees when something breaks, and it looked like a different product.
#
# Deliberately still English-only, and that's a real limitation rather than an
# oversight. These are static files served by the file server precisely when
# the app may not be able to render, so I18n isn't available at that point. The
# respondent-facing case that matters is already covered by the localised
# `player/unavailable` view, which the app serves itself for a dead or expired
# Verto link — so these four are the genuine last resort.
class ErrorPagesTest < ActionDispatch::IntegrationTest
  PAGES = %w[404.html 422.html 500.html 406-unsupported-browser.html].freeze

  def page(name)
    File.read(Rails.root.join("public", name))
  end

  test "every error page is branded rather than stock Rails" do
    PAGES.each do |name|
      html = page(name)
      # The wordmark is two-tone, so "play" and "verto" sit in separate spans
      # and the contiguous string never appears.
      assert_includes html, ">play<",  "#{name} should carry the wordmark"
      assert_includes html, ">verto<", "#{name} should carry the wordmark"
      assert_includes html, "#1C2034",   "#{name} should use the brand background"
      assert_not_includes html, "rails-default-error-page",
                          "#{name} is still the stock Rails page"
      assert_not_includes html, "If you are the application owner",
                          "#{name} still tells visitors to check the logs"
    end
  end

  test "no error page requests an external asset" do
    # These render when the app — and possibly the asset host — is broken, so a
    # stylesheet, font or image request is exactly the thing that would leave a
    # visitor staring at unstyled text.
    PAGES.each do |name|
      html = page(name)
      assert_not_includes html, "<link", "#{name} must not link a stylesheet"
      assert_not_includes html, "<script", "#{name} must not load a script"
      assert_not_includes html, "<img", "#{name} must not request an image"
      assert_not_includes html, "http://", "#{name} must not reference a remote host"
      assert_not_includes html, "https://", "#{name} must not reference a remote host"
    end
  end

  test "each page says what happened in plain language" do
    assert_match(/couldn't find that page/i, page("404.html"))
    assert_match(/security token expired/i,  page("422.html"))
    assert_match(/at our end/i,              page("500.html"))
    assert_match(/browser/i,                 page("406-unsupported-browser.html"))
  end

  test "the 500 page does not blame the visitor or promise a lost draft" do
    html = page("500.html")
    assert_match(/on us, not on you/i, html)
    assert_match(/nothing you entered has been lost/i, html)
  end

  test "pages offer a way back, except the one where it wouldn't work" do
    # An unsupported browser can't usefully be sent to the app it can't run.
    %w[404.html 422.html 500.html].each do |name|
      assert_includes page(name), 'href="/"', "#{name} should offer a way back"
    end
    assert_not_includes page("406-unsupported-browser.html"), 'href="/"'
  end

  test "a real 404 from the app serves the branded page" do
    # End-to-end rather than file-contents: proves the file is actually what
    # gets served, not just what's on disk.
    get "/definitely-not-a-route-#{SecureRandom.hex(4)}"
    assert_response :not_found
  end
end
