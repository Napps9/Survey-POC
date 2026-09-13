require "application_system_test_case"

# The cookie banner, driven for real. Every other system test presets the
# consent cookie (ApplicationSystemTestCase#setup) so the banner never shows;
# this is the one place its own behaviour keeps a browser test.
class CookieBannerTest < ApplicationSystemTestCase
  self.real_cookie_banner = true

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "cb-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Banner", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "welcome_card", "title" => "Hi" } ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def consent_cookie
    raw = page.driver.cookies[CONSENT_COOKIE_NAME]&.value
    raw && JSON.parse(CGI.unescape(raw))
  end

  # A player visit with every controller on the page connected. The banner is
  # not in the first paint: it is revealed by cookie-consent#connect, and
  # stimulus-loading fetches that module lazily, so a page under load can show
  # the card and its footer while the banner is still a hidden div.
  # wait_for_stimulus says on stderr if a page pays its whole ceiling.
  def open_player
    visit "/play/#{@survey.publish_token}"
    wait_for_stimulus
  end

  # What the page saw, for the failure message. 2026-09-13 this file failed
  # once in 513 at four workers with the banner still hidden five seconds after
  # the visit; no cookie had leaked from the previous test (probed), the
  # module had been fetched, and nothing else was recorded. Next time, the
  # failure carries the cookie, the navigation type (a reload would say so),
  # the banner's classes and whether its controller had connected.
  BANNER_STATE = <<~JS
    (() => {
      const app = window.Stimulus || window.application
      const root = document.querySelector("[data-controller~='cookie-consent']")
      return JSON.stringify({
        cookie: document.cookie,
        navigation: performance.getEntriesByType("navigation")[0]?.type,
        bannerClass: root?.className,
        controllerConnected: !!(app && root && app.getControllerForElementAndIdentifier(root, "cookie-consent"))
      })
    })()
  JS

  def assert_banner_button(name)
    assert page.has_button?(name, wait: 5),
           -> { "the cookie banner never showed '#{name}': #{page.evaluate_script(BANNER_STATE)}" }
  end

  test "shows on a first visit, and Accept all records the choice and hides it for good" do
    open_player
    assert_banner_button "Accept all"

    click_button "Accept all"
    assert_no_button "Accept all"
    assert_equal({ "necessary" => true, "analytics" => true }, consent_cookie)

    # The controllers have connected again, so a banner that was going to show
    # would have by now: the absence means something.
    open_player
    assert_no_button "Accept all"
  end

  test "Reject non-essential records the choice without analytics" do
    open_player
    assert_banner_button "Reject non-essential"

    click_button "Reject non-essential"
    assert_no_button "Reject non-essential"
    assert_equal({ "necessary" => true, "analytics" => false }, consent_cookie)
  end
end
