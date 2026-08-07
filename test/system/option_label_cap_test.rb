require "application_system_test_case"

# The 20-character cap on image-grid tile labels, and the counter that shows it.
#
# It has to be a browser test. The cap is a `beforeinput` guard on a
# contenteditable — there is no form field to assert a maxlength on, no request
# to inspect, and the whole point of choosing beforeinput over keydown is that
# it also catches paste, drop and IME commit, none of which a request test can
# produce.
#
# Why 20: the phone player draws a grid tile at a fixed proportion with one
# line of label under it, and 20 characters is what that line holds — measured
# at 16px, a 393px phone gives the column ~172px and ~8.6px a character. It is
# not a new number either: OPTION_LIMITS in lib/verto_rules has advised 20 for
# grid tiles all along, and the Rules of the Game panel already tells creators
# to shorten past it. This is the editor no longer advising something it
# declines to enforce.
class OptionLabelCapTest < ApplicationSystemTestCase
  CAP = 20         # grid tiles — enforced
  LIST_LIMIT = 40  # list rows — counted only

  CARDS = [
    { "type" => "welcome_card", "title" => "Hello" },
    { "type" => "select_one_grid", "cid" => "g1", "text" => "Which of these?",
      "options" => [ "Automation", "Brand building", "Measurement", "Creative work" ] },
    # A card written before the cap existed. Nothing may truncate it.
    { "type" => "select_many_grid", "cid" => "g2", "text" => "And which of these?",
      "options" => [ "A legacy label far too long for a tile", "Short one" ] },
    # A list type: full panel width, keeps its advisory-only 30, no hard cap.
    { "type" => "multiple_choice", "cid" => "m1", "text" => "Or one of these?",
      "options" => [ "Automation", "Brand building" ] }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "cap-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Cap", email_address: "cap-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "Cap", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Which of these?"
  end

  # The nth editable grid label on the page.
  def grid_label(n = 0)
    page.all("[data-card-type$='_grid'] .choice-label[contenteditable]", minimum: 1)[n]
  end

  def label_text(n = 0)
    grid_label(n).text
  end

  # Put the caret in a label and select everything already in it, so a typed
  # string replaces rather than appends.
  def focus_and_clear(el)
    el.click
    page.execute_script(<<~JS, el)
      const el = arguments[0]
      el.focus()
      const r = document.createRange(); r.selectNodeContents(el)
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r)
    JS
  end

  def counter
    page.has_css?(".option-limit-counter", wait: 2) ? find(".option-limit-counter") : nil
  end

  # ── The cap ──────────────────────────────────────────────────────────────

  test "a grid label stops at the cap however much is typed" do
    open_editor
    el = grid_label
    focus_and_clear(el)
    el.send_keys("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    assert_equal CAP, label_text.length,
                 "typed 36 characters into a #{CAP}-character tile and got #{label_text.inspect}"
  end

  # The reason this is a beforeinput guard and not a keydown one — a keydown
  # cap silently lets every paste straight through.
  test "a pasted string is capped too" do
    open_editor
    el = grid_label
    focus_and_clear(el)
    page.execute_script("document.execCommand('insertText', false, arguments[0])",
                        "Sustainability and purpose-led marketing")

    assert_equal 0, label_text.length % 1  # readability: the assertion below is the point
    assert_operator label_text.length, :<=, CAP,
                    "a 40-character paste landed as #{label_text.inspect}"
  end

  # A label already at the cap must still be REWRITABLE. Counting the pending
  # input against the full length rather than against what it replaces would
  # make a full label permanent — every keystroke refused, including the one
  # replacing the selection.
  test "selecting a full label and typing over it replaces rather than jams" do
    open_editor
    el = grid_label
    focus_and_clear(el)
    el.send_keys("12345678901234567890")   # exactly the cap
    assert_equal CAP, label_text.length

    focus_and_clear(el)
    el.send_keys("Fresh")

    assert_equal "Fresh", label_text,
                 "a label at the cap could not be typed over — the cap counts the whole " \
                 "label instead of what the input would replace"
  end

  # ── Existing content is never destroyed ──────────────────────────────────

  test "a label written before the cap is left alone until its creator edits it" do
    open_editor

    legacy = page.all("[data-card-type$='_grid'] .choice-label[contenteditable]")
                 .find { |el| el.text.start_with?("A legacy label") }

    assert legacy, "the over-length legacy label is not on the page"
    assert_operator legacy.text.length, :>, CAP,
                    "the legacy label was truncated on load — nothing may do that"
  end

  test "an over-length legacy label can still be shortened" do
    open_editor

    legacy = page.all("[data-card-type$='_grid'] .choice-label[contenteditable]")
                 .find { |el| el.text.start_with?("A legacy label") }
    before = legacy.text.length
    legacy.click
    10.times { legacy.send_keys(:backspace) }

    assert_operator legacy.text.length, :<, before,
                    "the cap must block insertion only — deleting from an over-length " \
                    "label has to keep working or it can never be brought under the limit"
  end

  # ── Lists: counted, never capped ─────────────────────────────────────────
  #
  # The asymmetry is the design, not an oversight. A grid tile's label sits in
  # a column under a fixed-proportion tile, so past 20 it wraps, the row grows,
  # and the tile stops matching its neighbours — the cap is load-bearing. A
  # list row spans the whole answer panel and the square tile beside it does
  # not depend on the label at all, so a long one just makes the row taller.
  # Nothing breaks, so nothing is refused: the count is a nudge toward the
  # Rules of the Game budget, measured at ~32 characters a line on an iPhone 15
  # against a grid tile's ~22.

  def list_row(type = "multiple_choice")
    page.all("[data-card-type='#{type}'] .pick-text[contenteditable]", minimum: 1).first
  end

  test "a list row is not capped — it has the width for a longer label" do
    open_editor
    row = list_row
    focus_and_clear(row)
    row.send_keys("A" * (LIST_LIMIT + 12))

    assert_operator row.text.length, :>, LIST_LIMIT,
                    "a list label must be able to pass #{LIST_LIMIT}; the hard cap is for " \
                    "grid TILES, where the width genuinely runs out"
  end

  test "a list row is counted, against its own higher limit" do
    open_editor
    row = list_row
    focus_and_clear(row)
    row.send_keys("Watching the recording")   # 22 — over a tile's cap, inside a list's

    c = counter
    assert c, "no counter appeared while a list label had focus"
    assert_match(/22\/#{LIST_LIMIT}/, c.text,
                 "a list label should be counted against #{LIST_LIMIT}, not the grid's #{CAP}")
    assert page.has_no_css?(".option-limit-counter.is-full", wait: 1),
           "22 characters is well inside a list's budget — nothing should read as full"
  end

  # Two hot states that mean different things, and they must not look alike:
  # a grid at its cap is a wall, a list past its budget is a line crossed.
  test "a list past its budget warns rather than stopping" do
    open_editor
    row = list_row
    focus_and_clear(row)
    row.send_keys("B" * (LIST_LIMIT + 3))

    assert_equal LIST_LIMIT + 3, row.text.length, "the keystrokes past #{LIST_LIMIT} were refused"
    assert page.has_css?(".option-limit-counter.is-over", wait: 2),
           "past its budget a list counter should show .is-over"
    assert page.has_no_css?(".option-limit-counter.is-full", wait: 1),
           ".is-full means the next keystroke does nothing, which is not true here — " \
           "a creator who learns pink means stop on a grid must not meet it on a list"
  end

  # ── The counter ──────────────────────────────────────────────────────────

  test "the counter appears on the label being edited and counts it" do
    open_editor
    el = grid_label
    focus_and_clear(el)
    el.send_keys("Automation")

    c = counter
    assert c, "no counter appeared while a tile label had focus"
    assert_match(/10\/#{CAP}/, c.text, "the counter should read the label's length over the cap")
  end

  test "the counter reads as full at the cap" do
    open_editor
    el = grid_label
    focus_and_clear(el)
    el.send_keys("12345678901234567890")

    assert counter, "no counter"
    assert page.has_css?(".option-limit-counter.is-full", wait: 2),
           "at the cap the counter should show as full — that is the moment the next " \
           "keystroke stops doing anything, and a silent cap reads as a broken keyboard"
  end

  test "the counter follows the focus rather than crowding every tile" do
    open_editor
    focus_and_clear(grid_label)

    assert_equal 1, page.all(".option-limit-counter", visible: :all).length,
                 "there should be exactly one counter, on the label being edited"

    page.execute_script("document.activeElement.blur()")

    assert page.has_no_css?(".option-limit-counter", wait: 2),
           "the counter should leave with the focus"
  end
end
