require "application_system_test_case"

# The scenario/consent book's page navigation is ONE capsule in the player —
# ‹ · · · › — not a dot strip floating above two grey circles.
#
# WHY. The footer's own Next already turns the book's pages (_scenarioTurn),
# so the chevrons were an unlabelled duplicate of the main button, and the
# floating footer left the card stacking two rows of round controls with
# nothing saying which "next" turns the page and which one skips the card.
# The owner was shown three treatments shot from the real player and picked
# this one: the chevrons and the dots fuse into a single brand-tinted pill,
# one instrument with one obvious job, a shape plainly different from the
# footer's pills.
#
# Ships with the page restyle every mocked treatment shared: warm paper
# instead of a white box on a white panel, and the stacked-page peek showing
# paper edges rather than readable content — the answer page's last option
# ("Not for me", on a green tile) was legible through the stack under the
# story, quietly spoiling the choices.
class BookPagerTest < ApplicationSystemTestCase
  PHONE   = [ 393, 768 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "bp-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Bp", email_address: "bp-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Pager", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "scenario", "cid" => "sc1", "text" => "What would you do?",
          "pages" => [ { "id" => "p1", "text" => "A card goes through your door." },
                       { "id" => "p2", "text" => "You have nothing else on that morning." } ],
          "options" => [ "I'd go", "I'd think about it", "Not for me" ] }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_player_scenario
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".preview-card.active .book-wrap", wait: 5
    sleep 0.4
  end

  # ── The capsule ───────────────────────────────────────────────────────────

  test "the player's page navigation is one capsule: chevron, dots, chevron" do
    open_player_scenario
    row = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector(".preview-card.active .book-nav-row")
        const cs = getComputedStyle(row)
        return {
          kids: [ ...row.children ].map(el => el.className.split(" ")[0]),
          bg: cs.backgroundColor,
          radius: cs.borderRadius,
          chevronOwnSurface: getComputedStyle(row.querySelector(".book-chevron")).borderTopWidth
        }
      })()
    JS

    assert_equal %w[book-chevron book-dots book-chevron], row["kids"],
                 "the nav row holds #{row['kids'].inspect}. The dots belong BETWEEN the " \
                 "chevrons in the player — that adjacency is what fuses three orphaned " \
                 "controls into one pager. With the dots back above the row, the card is " \
                 "again a dot strip floating over two anonymous circles, 60px from a teal " \
                 "button that does the same thing."
    refute_equal "rgba(0, 0, 0, 0)", row["bg"],
                 "the nav row has no surface of its own, so the chevrons and dots read as " \
                 "scattered controls rather than one capsule — the pill background is the " \
                 "thing that binds them."
    assert_equal "100px", row["radius"], "the capsule lost its pill shape"
    assert_equal "0px", row["chevronOwnSurface"],
                 "a chevron still draws its own border inside the capsule — two nested " \
                 "circles-in-a-pill is the cluttered look this replaced. The capsule is the " \
                 "surface; the chevrons are glyphs on it."
  end

  test "the editor keeps its own row: dots above, full-width next-page button" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "A card goes through your door."

    editor = page.evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector("[data-card-cid='sc1'] .book-wrap")
        const row = wrap.querySelector(".book-nav-row")
        return {
          dotsInRow: !!row.querySelector(".book-dots"),
          hasNextBtn: !!row.querySelector(".next-btn")
        }
      })()
    JS

    refute editor["dotsInRow"],
           "the editor's dots moved inside the nav row. The pill is a respondent control; " \
           "the editor's row carries the full-width 'Next page ›' button, which a capsule " \
           "cannot hold — this guards the editable/player split in _card_component's book " \
           "branches from being 'simplified' into one shape."
    assert editor["hasNextBtn"], "the editor's full-width next-page button is gone"
  end

  # ── The peek ──────────────────────────────────────────────────────────────

  test "the stacked-page peek shows paper, not the answer's options" do
    open_player_scenario
    peek = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        return {
          hidden: [ ...card.querySelectorAll('.book-page[aria-hidden="true"] .book-page-scroll') ]
            .map(el => getComputedStyle(el).visibility),
          current: getComputedStyle(
            card.querySelector('.book-page[aria-hidden="false"] .book-page-scroll')).visibility,
          pageBg: getComputedStyle(card.querySelector(".book-page")).backgroundColor
        }
      })()
    JS

    assert_operator peek["hidden"].size, :>=, 2, "expected at least two stacked pages behind page 1"
    assert peek["hidden"].all? { |v| v == "hidden" },
           "a non-current page's content is #{peek['hidden'].inspect}. The stack peeks out " \
           "under the current page on purpose — it says 'there's more' — but with content " \
           "visible it spoils the choices: the answer's last option was readable through " \
           "the stack under the story."
    assert_equal "visible", peek["current"], "the current page's own content is hidden — the fix ate the story"
    assert_equal "rgb(253, 252, 247)", peek["pageBg"],
                 "the page is #{peek['pageBg']}, not paper. White-on-white was half the " \
                 "complaint: a white box floating on a white panel."
  end

  # The half a screenshot can never show: a page being turned away gets
  # aria-hidden at turn START, so an instant visibility flip would blank it
  # mid-rotation and the turn would read as a card flipping over empty. The
  # hide is delayed past the 0.52s rotation instead.
  test "a departing page keeps its words through the turn" do
    open_player_scenario
    # evaluate_async_script, because plain evaluate_script does not await a
    # promise under Cuprite — it returned nil here and the test failed for a
    # reason it did not own.
    anim = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const card = document.querySelector(".preview-card.active")
      const departing = card.querySelector('.book-page[aria-hidden="false"]')
      const chevrons = card.querySelectorAll(".book-chevron")
      chevrons[chevrons.length - 1].click()
      setTimeout(() => {
        const mid = getComputedStyle(departing.querySelector(".book-page-scroll")).visibility
        setTimeout(() => {
          done({ mid, settled: getComputedStyle(departing.querySelector(".book-page-scroll")).visibility })
        }, 700)
      }, 200)
    JS

    assert_equal "visible", anim["mid"],
                 "200ms into a 520ms page turn the departing page's content is already " \
                 "hidden — the rotation is showing blank paper. The visibility flip has to " \
                 "wait out the turn (transition: visibility 0s 0.55s on the hidden state)."
    assert_equal "hidden", anim["settled"],
                 "the turn finished and the departing page's content is still visible — the " \
                 "delay exists to protect the animation, not to disable the peek fix."
  end
end
