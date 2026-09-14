require "application_system_test_case"

# The respondent dashboard, in a browser.
#
# The integration suite pins what the server renders — the tiles, the cards,
# which CTA is primary, which section is drawn. Three things it cannot see, and
# they are the three here: the account menu is a Stimulus controller (it opens
# on a click and closes on Escape and on a click outside, and none of that is
# in the HTML), setting a password from that menu is a journey across three
# pages, and the phone layout is CSS — the centre chips and the account name
# are hidden by a media query, and the tiles reflow to two columns, which only
# a browser at 390px can confirm.
class YouDashboardTest < ApplicationSystemTestCase
  def org = Organisation.create!(name: "Haverley", slug: "yd-#{SecureRandom.hex(3)}")

  def verto(owner, theme)
    owner.surveys.create!(
      title: "T", theme: theme, audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def played(survey)
    survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                             answered: true, completed_at: 1.day.ago)
  end

  # Through the real link, because that is the only door into an account that
  # does not yet have a password, and a stubbed session would be testing a
  # fixture rather than the app.
  def sign_in_with(responses)
    player = Player.for_email("yd-#{SecureRandom.hex(4)}@test.com")
    _link, raw = PlayerSignInLink.mint!(
      player: player,
      claim_payload: responses.map { |r| { "response_id" => r.id, "source" => "signup" } })
    visit player_sign_in_path(raw)
    dismiss_cookie_banner
    click_button I18n.t("player_sign_in.cta")
    assert_selector ".you-topbar", wait: 10
    player
  end

  def box_for(selector)
    evaluate_script(
      %{(() => { const e = document.querySelector(#{selector.to_json});
                 if (!e) return null;
                 const r = e.getBoundingClientRect();
                 return { top: r.top, left: r.left, right: r.right, width: r.width }; })()}
    )
  end

  test "signing in lands on the dashboard, with the tiles and a card per Verto" do
    o = org
    sign_in_with([ played(verto(o, "Car-free High Street")), played(verto(o, "Riverside")) ])

    assert_selector ".you-h1-hero"
    assert_selector ".you-tile", count: 4
    assert_selector ".you-tile.is-teal .you-tile-value", text: "2"
    assert_selector ".you-verto", count: 2
    assert_text "Car-free High Street"
    assert_text "Riverside"
    # One primary per card, always — the rule the whole card layout is built on.
    assert_selector ".you-cta-primary", count: 2
  end

  test "the account menu opens on a click and closes on Escape and on a click outside" do
    sign_in_with([ played(verto(org, "Car-free High Street")) ])

    assert_no_selector ".you-account-popover", visible: true
    find(".you-account-btn").click
    assert_selector ".you-account-popover", visible: true
    assert_selector ".you-account-btn[aria-expanded=true]"

    press_keys :escape
    assert_no_selector ".you-account-popover", visible: true
    assert_selector ".you-account-btn[aria-expanded=false]"

    find(".you-account-btn").click
    assert_selector ".you-account-popover", visible: true
    find(".you-h1-hero").click
    assert_no_selector ".you-account-popover", visible: true
  end

  test "the menu reaches the account page, where a password can be set" do
    sign_in_with([ played(verto(org, "Car-free High Street")) ])

    find(".you-account-btn").click
    click_link I18n.t("you.menu_account")

    assert_current_path you_account_path
    assert_selector ".you-panel", minimum: 4
    fill_in I18n.t("you.new_password"), with: "a-very-long-password"
    fill_in I18n.t("you.confirm_password"), with: "a-very-long-password"
    click_button I18n.t("you.set_password")

    assert_selector ".you-flash.is-notice", text: I18n.t("you.password_set")
  end

  test "on a phone the chips and the name give way, and the tiles are two columns" do
    o = org
    sign_in_with([ played(verto(o, "Car-free High Street")), played(verto(o, "Riverside")) ])

    with_viewport(390, 844) do
      # The media query is CSS, so the elements are still in the DOM — what
      # changes is whether they are drawn, and what the grid does with them.
      assert_no_selector ".you-topbar-centre", visible: true
      assert_no_selector ".you-account-name", visible: true
      assert_selector ".you-avatar", visible: true

      first_tile  = box_for(".you-tile:nth-of-type(1)")
      second_tile = box_for(".you-tile:nth-of-type(2)")
      third_tile  = box_for(".you-tile:nth-of-type(3)")
      assert_in_delta first_tile["top"], second_tile["top"], 1,
                      "the first two tiles are not on the same row"
      assert_operator third_tile["top"], :>, first_tile["top"],
                      "the third tile did not wrap to a second row"

      # Nothing may push the page sideways at phone width.
      assert_equal 390, evaluate_script("document.documentElement.scrollWidth")
    end
  end
end
