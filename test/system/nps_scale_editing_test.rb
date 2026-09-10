require "application_system_test_case"

# Building an NPS scale.
#
# The labels have always driven the step count — swap them for an agree range
# and the vessel fills in that many steps — but the editor gave no way to change
# HOW MANY there were. So a creator could rename the eleven stops and nothing
# else: no fifth-point scale, no removing the ones they didn't want.
#
# The reason it was locked is a real one, though, and it is why this is a switch
# rather than an unconditional ＋: an NPS is 0-10, and a score only means
# anything against the same eleven-point question everybody else asks. So the
# classic stays the default and the lock comes off deliberately.
#
# The whole path in a browser, because every link in it is somewhere the count
# can silently disagree with itself: the switch has to rebuild the column, the
# ＋ and × have to move the widget's own step count with them (or the liquid
# lands between two labels), and the deck has to still be carrying the scale
# after the autosave round-trip.
class NpsScaleEditingTest < ApplicationSystemTestCase
  AGREE = [ "Never", "Rarely", "Sometimes", "Often", "Always" ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Scale", slug: "scale-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Scale", email_address: "scale-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Scale", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        # No `options` at all — the commonest shape in the wild, and the one
        # that has to read as classic without a flag being stored on it.
        { "type" => "nps", "cid" => "n1", "text" => "How likely?" },
        # A deck that was already carrying its own scale before the switch
        # existed. Nothing may lock this one or replace its labels.
        { "type" => "nps", "cid" => "n2", "text" => "How often?", "options" => AGREE.dup }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How likely?"
  end

  def select_card(cid)
    find("[data-card-cid='#{cid}'] .split-right").click
    assert_selector "[data-survey-editor-target='npsClassic']:not([hidden])", wait: 5
  end

  # The switch is a .card-flag, whose <input> is the 1px transparent box the
  # painted track sits over — so the label is what a creator clicks and what a
  # test has to click, and the input is only ever read.
  def classic_switch
    find("[data-survey-editor-target='panelNpsClassic']", visible: :all)
  end

  def toggle_classic
    was = classic_switch.checked?
    find("[data-survey-editor-target='npsClassic'] .card-flag").click
    assert_equal !was, classic_switch.checked?, "the classic switch did not change state"
  end

  # Remove one stop, named by its label.
  #
  # Two things have to be got right before the click, and the second one cost a
  # full-suite run to find:
  #
  #   - the × chips are dimmed until the scale is hovered, exactly as a pick
  #     list's are, so the pointer has to be over the card first;
  #   - .editor-feed is `scroll-snap-type: y mandatory`. Ferrum clicks by
  #     COORDINATES: it scrolls the chip into view, the mandatory snap then
  #     re-settles the feed to the nearest card centre, and a click issued
  #     against the pre-snap position lands on whatever has moved under it.
  #     Measured: asking for the bottom stop deleted the one two rows up.
  #     Scrolling the CARD — a snap target, so the snap has nothing to correct
  #     — and letting it settle is what stops that.
  #
  # And it clicks the chip belonging to the label asked for rather than
  # whichever is first in the DOM, so a click that ever does land wrong says so
  # instead of quietly removing a neighbour.
  def press_delete(cid, label)
    card = "[data-card-cid='#{cid}']"
    page.execute_script(%(document.querySelector("#{card}").scrollIntoView({ block: "center" })))
    sleep 0.5
    find("#{card} .nps-slider").hover

    index = evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#{card} .nps-label-row"))
           .findIndex(r => r.querySelector(".slider-label-text").textContent.trim() === "#{label}")
    JS
    assert_operator index, :>=, 0, "no stop labelled #{label.inspect} on #{cid}"

    all("#{card} .nps-label-delete")[index].click
  end

  def delete_stop(cid, label)
    press_delete(cid, label)
    refute_includes scale(cid)["labels"], label,
                    "asked to remove #{label.inspect} and it is still there — the click landed " \
                    "on a different stop"
  end

  def scale(cid)
    evaluate_script(<<~JS)
      (() => {
        const wrap   = document.querySelector("[data-card-cid='#{cid}']")
        const slider = wrap.querySelector(".nps-slider")
        return {
          labels:  Array.from(wrap.querySelectorAll(".nps-label-row .slider-label-text")).map(e => e.textContent.trim()),
          rows:    wrap.querySelectorAll(".nps-label-row").length,
          steps:   Number(slider.dataset.npsSliderStepsValue),
          valuemax: Number(slider.getAttribute("aria-valuemax")),
          deletes: wrap.querySelectorAll(".nps-label-delete").length,
          hasAdd:  !!wrap.querySelector(".nps-scale-add"),
          custom:  wrap.dataset.cardNpsCustomScale || ""
        }
      })()
    JS
  end

  def stored(cid)
    30.times do
      card = @survey.reload.cards.find { |c| c["cid"] == cid }
      return card if yield(card)
      sleep 0.5
    end
    @survey.reload.cards.find { |c| c["cid"] == cid }
  end

  test "a classic card offers no way to change the scale until the switch comes off" do
    open_editor
    s = scale("n1")

    assert_equal 11, s["rows"], "the classic scale is not eleven stops"
    assert_equal 0, s["deletes"], "a classic 0-10 card is offering to delete its stops"
    refute s["hasAdd"], "a classic 0-10 card is offering to add a twelfth stop"

    select_card("n1")
    assert classic_switch.checked?,
           "a card with no stored labels reads as off the classic scale — it renders as 0-10, " \
           "so nothing has changed and the switch must say so"
  end

  # The migration-free half, and the one that would be expensive to get wrong:
  # a deck already carrying its own scale must not be locked, and above all must
  # not have its labels replaced by eleven digits.
  test "a card that already had its own scale opens unlocked, labels intact" do
    open_editor
    s = scale("n2")

    assert_equal AGREE, s["labels"], "an existing custom scale lost its labels"
    assert_equal 5, s["deletes"], "an existing custom scale opened with no way to edit it"
    assert s["hasAdd"]

    select_card("n2")
    refute classic_switch.checked?,
           "a card carrying an agree scale is reading as classic"
  end

  test "unlocking a classic card grows the controls, and locking it puts 0-10 back" do
    open_editor
    select_card("n1")

    toggle_classic   # off
    assert_selector "[data-card-cid='n1'] .nps-scale-add", wait: 5
    unlocked = scale("n1")
    assert_equal 11, unlocked["deletes"], "every stop should have gained a ×"
    assert_equal "true", unlocked["custom"], "the unlock was not recorded on the card"

    # Cut it down to a five-point scale, from the bottom up: 0-10 becomes 6-10.
    (0..5).each { |i| delete_stop("n1", i.to_s) }
    cut = scale("n1")
    assert_equal 5, cut["rows"]
    assert_equal 5, cut["steps"],
                 "the widget still thinks it has #{cut['steps']} steps, so the liquid will land " \
                 "between two labels"
    assert_equal 4, cut["valuemax"]

    card = stored("n1") { |c| Array(c["options"]).size == 5 }
    assert_equal 5, Array(card["options"]).size, "the shortened scale did not reach the deck"
    assert_equal true, card["nps_custom_scale"]

    # …and back to the classic, which is the destructive direction on purpose.
    toggle_classic   # on
    relocked = scale("n1")
    assert_equal (0..10).map(&:to_s), relocked["labels"],
                 "locking the switch did not put the classic 0-10 back"
    assert_equal 0, relocked["deletes"]
    refute relocked["hasAdd"]

    card = stored("n1") { |c| Array(c["options"]).size == 11 }
    assert_equal 11, Array(card["options"]).size
    refute card.key?("nps_custom_scale"), "the unlock outlived the re-lock"
  end

  test "adding a stop continues a numeric scale and stops at the classic's ceiling" do
    open_editor
    select_card("n1")
    toggle_classic   # off
    assert_selector "[data-card-cid='n1'] .nps-scale-add", wait: 5

    # At eleven the ＋ is already at the ceiling: disabled, not missing, so the
    # limit stays legible instead of the control simply vanishing.
    assert find("[data-card-cid='n1'] .nps-scale-add").disabled?,
           "the ＋ is live on a scale already at the classic's eleven points"

    # The × chips come in DOM order, and DOM order is the BOTTOM of the scale
    # first — the column is `column-reverse`, so index 0 draws lowest. Deleting
    # the first one takes "0" off the bottom and leaves 1-10.
    delete_stop("n1", "0")
    refute find("[data-card-cid='n1'] .nps-scale-add").disabled?
    assert_equal (1..10).map(&:to_s), scale("n1")["labels"]

    find("[data-card-cid='n1'] .nps-scale-add").click
    s = scale("n1")
    assert_equal 11, s["rows"]
    # …and a stop is added at the TOP, carrying the sequence on rather than
    # dropping a "New option" into the middle of a run of numbers.
    assert_equal "11", s["labels"].last,
                 "a numeric scale should carry on counting rather than gaining a placeholder"
    assert_equal (1..11).map(&:to_s), s["labels"]
  end

  # The ×'s own floor. Below two stops there is nothing to drag, and the
  # renderer clamps to two anyway — so a card cut to one would show one label
  # against a two-step vessel.
  test "the scale cannot be cut below two stops" do
    open_editor
    select_card("n2")

    AGREE.first(3).each { |label| delete_stop("n2", label) }
    assert_equal AGREE.last(2), scale("n2")["labels"]

    # press_delete, not delete_stop: this one is SUPPOSED to do nothing, so the
    # helper that asserts the label went is the wrong one to ask.
    press_delete("n2", AGREE.last)
    assert_equal AGREE.last(2), scale("n2")["labels"],
                 "the floor let the scale fall below two stops"
  end
end
