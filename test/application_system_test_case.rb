require "test_helper"
require "capybara/rails"
require "capybara/cuprite"

# Browser tests (P2-5). Until now the suite was integration-level only, so
# anything that lives in JavaScript could be checked by hand in a browser and
# then only guarded by asserting on source text. The player's keyboard and
# focus behaviour (P2-4) is exactly that shape, and it's what this exists for.
#
# Cuprite rather than Selenium: it drives Chrome over CDP, so there is no
# chromedriver to install or version-match. That's what lets one configuration
# work both on the GitHub runner, where `google-chrome` is on PATH, and in a
# container that only has a Playwright-managed binary.
#
# These do NOT run under `bin/rails test` — Rails keeps test/system out of the
# default set, and CI runs them as their own step. A browser hiccup should not
# be able to take the unit suite, and therefore the deploy, down with it.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # First existing path wins. BROWSER_PATH overrides everything, then the
  # container's Playwright binary, then whatever a normal Linux CI image has.
  BROWSER_CANDIDATES = [
    ENV["BROWSER_PATH"],
    "/opt/pw-browsers/chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium-browser",
    "/usr/bin/chromium"
  ].compact.freeze

  # nil is a deliberate fallback rather than a failure: Ferrum does its own
  # Chrome detection, so an image that puts the binary somewhere unlisted still
  # works instead of erroring on a path guess.
  def self.browser_path
    BROWSER_CANDIDATES.find { |path| File.executable?(path.to_s) }
  end

  Capybara.register_driver(:cuprite_headless) do |app|
    Capybara::Cuprite::Driver.new(
      app,
      window_size: [ 1280, 900 ],
      browser_path: browser_path,
      # --no-sandbox is required in a container running as root and on most CI
      # images; there is no untrusted content here, only our own app.
      browser_options: { "no-sandbox": nil, "disable-gpu": nil, "disable-dev-shm-usage": nil },
      process_timeout: 30,
      timeout: 20,
      headless: true
    )
  end

  driven_by :cuprite_headless

  # The player writes to sessionStorage and registers a Service Worker, so each
  # test starts from a clean slate rather than inheriting the last one's.
  def setup
    super
    page.driver.clear_memory_cache if page.driver.respond_to?(:clear_memory_cache)
  end

  # Sign in through the real form. The password field is submitted with Enter
  # deliberately: a generic submit selector on these pages hits the language
  # switcher instead.
  def sign_in_as(user, password: "verylongpassword")
    visit new_session_path
    fill_in "email_address", with: user.email_address
    fill_in "password", with: password
    find("input[name=password]").send_keys(:enter)
    assert_no_current_path new_session_path, wait: 5
  end

  # The cookie banner overlays the bottom of every page and will swallow clicks
  # aimed at anything underneath it.
  def dismiss_cookie_banner
    click_button "Accept all" if has_button?("Accept all", wait: 2)
  end
end
