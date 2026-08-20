require "application_system_test_case"

# The question is the point of the card, and it must never be the thing that
# falls off it.
#
# .split-right is a fixed-height flex column that centres its children. A centred
# flex line puts overflow at BOTH ends, so a card holding more than fits pushes
# .q-header to a negative offset and .split-card's overflow:hidden takes the top
# of the question away. .q-header also carries flex: 0 0 auto, so it cannot give
# up height to relieve the pressure — it can only leave the frame.
#
# The app has had the cure since long lists needed it: .split-right > .mt-2
# becomes a scroll container, the overflow is absorbed inside the answer box, and
# the flex line never overflows. But it was :has()-scoped to four answer shapes —
# lists, grids, prioritise and the contact form (since retired). The five types below had no
# scroll path at all, so for them overflow was silent clipping.
#
# It has shipped, too: one_pager_fit_test's header records "1000x567 cut 82px off
# the top of every card", and the since-deleted contact_form_sideways_test was
# written after the same failure on a sideways phone (that card type has since
# been retired; this file is where its assertion lives on). This is that
# assertion generalised to the two
# surfaces that share the fixed 850x680 box — the editor canvas and the desktop
# player — across every type that was excluded.
class CardHeaderPinnedTest < ApplicationSystemTestCase
  # Long enough to wrap, with a description under it, because that is the shape
  # the owner hit: it is the SECOND line plus the subtitle that tips the column
  # over its budget, not an unreasonable essay.
  QUESTION = "What draws you to racing, and which parts of it would you keep " \
             "if you could only keep one?".freeze
  DESCRIPTION = "Think about a normal week rather than a race weekend.".freeze

  # Every type that had no scroll path before this. Deliberately NOT the four
  # that already had one — those are covered and would pass either way.
  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "title" => "Hello" },
    { "type" => "tap_card",   "cid" => "tap",  "text" => QUESTION, "description" => DESCRIPTION,
      "options" => [ "They drain the life out of me", "I get more done in them" ] },
    { "type" => "range",      "cid" => "rng",  "text" => QUESTION, "description" => DESCRIPTION,
      "options" => [ "Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree" ] },
    { "type" => "nps",        "cid" => "nps",  "text" => QUESTION, "description" => DESCRIPTION },
    { "type" => "rating",     "cid" => "rate", "text" => QUESTION, "description" => DESCRIPTION,
      "options" => [ "Poor", "Fair", "Good", "Great", "Superb" ] },
    { "type" => "open_ended", "cid" => "free", "text" => QUESTION, "description" => DESCRIPTION }
  ].freeze

  TYPES = %w[tap_card range nps rating open_ended].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "chp-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Chp", email_address: "chp-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Pinned", theme: "Sport", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS
    )
  end

  def publish!
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # Is the question inside the box the card is clipped to, and can the answer
  # still be reached? Returns one hash per card so a failure names the type.
  #
  # Measured against .split-card rather than the viewport: that is the element
  # carrying overflow: hidden, so it is the edge the question actually
  # disappears behind.
  def header_report(scope)
    evaluate_script(<<~JS)
      (() => {
        return [...document.querySelectorAll(#{scope.to_json})].map((card) => {
          const box  = card.querySelector(".split-card") || card
          const head = card.querySelector(".q-header")
          const mt   = card.querySelector(".split-right > .mt-2")
          if (!head) return null
          const b = box.getBoundingClientRect(), h = head.getBoundingClientRect()
          return {
            type: card.dataset.cardType || card.getAttribute("data-card-type") || "?",
            clippedBy: Math.round(b.top - h.top),   // > 0 means the top is cut off
            overflowY: mt ? getComputedStyle(mt).overflowY : null,
            hidden: mt ? Math.round(mt.scrollHeight - mt.clientHeight) : 0
          }
        }).filter(Boolean)
      })()
    JS
  end

  def assert_headers_pinned(rows, where)
    assert_equal TYPES.sort, rows.map { |r| r["type"] }.sort,
                 "expected one report per excluded type in the #{where}"

    clipped = rows.select { |r| r["clippedBy"].to_i > 0 }
    assert_empty clipped.map { |r| "#{r['type']} (#{r['clippedBy']}px of the question cut off)" },
                 "the question is being clipped by the top of the card in the #{where}. That is " \
                 "the one thing a card may not lose: a respondent can answer a question with no " \
                 "photograph, but not one they cannot read."
  end

  # Anything that overflows must be reachable rather than merely uncut. A card
  # that stopped clipping because the answer widget got silently squashed would
  # pass the assertion above and still be broken.
  def assert_overflow_reachable(rows, where)
    stuck = rows.select { |r| r["hidden"].to_i > 0 && r["overflowY"] != "auto" }
    assert_empty stuck.map { |r| "#{r['type']} (#{r['hidden']}px unreachable)" },
                 "in the #{where} these answer areas overflow with no way to scroll to the rest — " \
                 "the content is simply gone"
  end

  test "the editor never cuts the question off the top of the card" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-card-type='tap_card']", wait: 10

    rows = header_report("[data-survey-editor-target='card'][data-card-type]")
              .select { |r| TYPES.include?(r["type"]) }
    assert_headers_pinned(rows, "editor")
    assert_overflow_reachable(rows, "editor")
  end

  # The desktop player inherits the same 850x680 .split-card and the same centred
  # panel — the mobile breakpoint is the only place that escapes them. So this is
  # not an editor-only guard.
  test "the desktop player never cuts the question off the top of the card" do
    publish!
    page.driver.browser.resize(width: 1280, height: 900)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)

    seen = []
    TYPES.length.times do
      click_button "Next" if has_button?("Next", wait: 3)
      sleep 0.4
      seen.concat(header_report(".preview-card.active").select { |r| TYPES.include?(r["type"]) })
    end

    assert_headers_pinned(seen.uniq { |r| r["type"] }, "desktop player")
    assert_overflow_reachable(seen.uniq { |r| r["type"] }, "desktop player")
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end
end
