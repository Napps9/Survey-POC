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

  test "shows on a first visit, and Accept all records the choice and hides it for good" do
    visit "/play/#{@survey.publish_token}"
    assert_button "Accept all", wait: 5

    click_button "Accept all"
    assert_no_button "Accept all"
    assert_equal({ "necessary" => true, "analytics" => true }, consent_cookie)

    visit "/play/#{@survey.publish_token}"
    assert_no_button "Accept all", wait: 2
  end

  test "Reject non-essential records the choice without analytics" do
    visit "/play/#{@survey.publish_token}"
    assert_button "Reject non-essential", wait: 5

    click_button "Reject non-essential"
    assert_no_button "Reject non-essential"
    assert_equal({ "necessary" => true, "analytics" => false }, consent_cookie)
  end
end
