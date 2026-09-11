require "application_system_test_case"

# The wallet pill in the top corner of the respondent account.
#
# The integration suite pins what the server renders — the total, the rows, the
# CTA, the aria. What it cannot see is the only thing that makes this a pill
# rather than a tab: the panel is hidden until a pointer arrives, and it has to
# survive the pointer travelling from the pill into it across the gap between
# them. That gap is bridged by a pseudo-element, which is CSS, which means a
# browser is the only thing that can say whether it holds.
class YouWalletPillTest < ApplicationSystemTestCase
  def org = Organisation.create!(name: "O", slug: "wp-#{SecureRandom.hex(3)}")

  # Both Vertos use the token id "gold" for two different things, which is the
  # ordinary case rather than a contrived one — Survey#duplicate! copies
  # token_types verbatim. The breakdown must keep them apart.
  def verto(owner, theme, name, icon, amount)
    s = owner.surveys.create!(
      title: "T", theme: theme, audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      tokenisation_enabled: true,
      token_types: [ { "id" => "gold", "name" => name, "icon" => icon } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        completed_at: 1.day.ago, token_totals: { "gold" => amount })
  end

  # Through the real link, because that is the only door into an account and a
  # stubbed session would be testing a fixture rather than the app.
  def sign_in_with(responses)
    player = Player.for_email("wp-#{SecureRandom.hex(4)}@test.com")
    _link, raw = PlayerSignInLink.mint!(
      player: player,
      claim_payload: responses.map { |r| { "response_id" => r.id, "source" => "signup" } })
    visit player_sign_in_path(raw)
    dismiss_cookie_banner
    click_button I18n.t("player_sign_in.cta")
    assert_selector ".you-purse-pill", wait: 10
  end

  def box_for(selector)
    evaluate_script(
      %{(() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect();
                 return { top: r.top, left: r.left, right: r.right,
                          x: Math.round(r.left + r.width / 2),
                          y: Math.round(r.top + r.height / 2) }; })()}
    )
  end

  # A pointer travelling from one element to another, dispatching a move at
  # every step on the way. Capybara's own #hover jumps straight to the target,
  # so it can never see anything about the ground in between.
  def walk_pointer(from, to)
    a = box_for(from)
    b = box_for(to)
    mouse = page.driver.browser.page.mouse
    mouse.move(x: a["x"], y: a["y"])
    mouse.move(x: b["x"], y: b["y"], steps: 12)
  end

  test "the breakdown is hidden until a pointer arrives, and survives the trip into it" do
    o = org
    sign_in_with([ verto(o, "Car-free High Street", "Ideas", "🚲", 34),
                   verto(o, "Riverside", "Green", "🌳", 88) ])

    assert_text "122"
    assert_no_selector ".you-purse-popover", visible: true

    find(".you-purse-pill").hover
    assert_selector ".you-purse-popover", visible: true
    within(".you-purse-popover") do
      assert_text "Car-free High Street"
      assert_text "Riverside"
      assert_text "Ideas"
      assert_text "Green"
    end

    # The panel is a sibling of the pill with 8px of air between them, and the
    # pointer has to cross that air to reach the CTA. Walked rather than
    # jumped: a jump lands inside the panel and never touches the gap, which is
    # the whole thing under test.
    walk_pointer(".you-purse-pill", ".you-purse-all")
    assert_selector ".you-purse-popover", visible: true
    find(".you-purse-all").click

    assert_current_path you_wallet_path
    assert_selector ".you-total", text: "122"
  end

  test "the pill itself opens the wallet, which is what a tap does" do
    o = org
    sign_in_with([ verto(o, "Car-free High Street", "Ideas", "🚲", 34) ])

    find(".you-purse-pill").click

    assert_current_path you_wallet_path
    assert_selector ".you-purse-pill.is-on"
    assert_selector ".you-total", text: "34"
  end

  test "the pill sits beside the language button rather than under it" do
    o = org
    sign_in_with([ verto(o, "Car-free High Street", "Ideas", "🚲", 34) ])

    pill = box_for(".you-purse-pill")
    lang = box_for(".lang-switcher-btn")

    # Both in the top corner, and not overlapping: they share one fixed
    # cluster, and the bug this guards is the pill landing on top of a language
    # button whose width depends on the code inside it.
    assert_operator pill["top"], :<, 60, "the pill is not in the top corner"
    assert_operator pill["right"], :<=, lang["left"] + 1,
                    "the pill overlaps the language button"
  end

  test "moving the pointer away closes it, and Escape closes it at once" do
    o = org
    sign_in_with([ verto(o, "Car-free High Street", "Ideas", "🚲", 34) ])

    find(".you-purse-pill").hover
    assert_selector ".you-purse-popover", visible: true

    find(".you-h1").hover
    assert_no_selector ".you-purse-popover", visible: true

    find(".you-purse-pill").hover
    assert_selector ".you-purse-popover", visible: true
    find("body").send_keys(:escape)
    assert_no_selector ".you-purse-popover", visible: true
  end
end
