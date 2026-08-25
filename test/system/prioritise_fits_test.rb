require "application_system_test_case"

# A prioritise card shows every option at once, or it is broken.
#
# This is a stronger promise than "the answer scrolls if it must", which is
# what every other list card gets, and the reason is in the CSS: the whole row
# is the drag handle, so .prioritise-item is `touch-action: none` (search
# "Prioritise (drag-to-rank list)"). pan-y was tried and told the browser that
# every touch-drag on a row was a scroll — it fired pointercancel and
# drag-to-rank simply never worked on touch.
#
# The cost of that trade is this file. A finger cannot scroll the list; it can
# only drag a row. So a row below the fold is not "further down", it is
# UNREACHABLE, and a ranking submitted without it ranks the wrong set. The
# owner photographed it: four options, the fourth sitting behind the floating
# Back/Next pills.
#
# The fix is that prioritise drops its mobile hero strip the way NPS and the
# tap matrix already do, so the list has the whole card. These tests hold the
# result at the three tightest upright phones rather than at one, because the
# margin is what is being claimed.
class PrioritiseFitsTest < ApplicationSystemTestCase
  # Clearance, not merely "not behind" — the CLEAR_PX convention from
  # floating_footer_test: an option landing exactly on the pills' top edge
  # measures clear and reads as touching.
  CLEAR_PX = 8

  # The upright phones from player_type_floor_test's matrix, smallest first.
  # A landscape phone is deliberately absent: 844x390 cannot hold five rows
  # under any layout, and this file is about the ones that can.
  UPRIGHT = {
    "Galaxy Fold" => [ 280, 653 ],
    "iPhone SE"   => [ 375, 553 ],
    "iPhone 15"   => [ 393, 660 ]
  }.freeze

  # Five, because COUNT_RULES bounds the type at 4-5 (verto_rules.js) and five
  # is therefore the worst case the editor is meant to be able to produce.
  OPTIONS = [ "Cheaper sessions", "More times to choose", "Friendlier clubs",
              "Better facilities", "Closer to home" ].freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "pfit-#{SecureRandom.hex(3)}")
    # WITH an image: a prioritise card carrying media is the case that also
    # exercises the bar-clearance re-assert, since the media reset would
    # otherwise put the progress bar back under the eyebrow.
    @survey = @org.surveys.create!(
      title: "Fits", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Welcome" },
        { "type" => "prioritise", "cid" => "p1", "image" => "/nope.jpg",
          "text" => "Drag these into the order that matters to you.",
          "options" => OPTIONS.dup }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  def open_at(width, height)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".preview-card.active .prioritise-item", minimum: OPTIONS.size, wait: 5
    sleep 0.5
  end

  # Everything this file argues about, measured in one pass.
  def fit_report
    page.evaluate_script(<<~JS)
      (() => {
        const card  = document.querySelector(".preview-card.active")
        const pills = document.querySelector(".preview-footer").getBoundingClientRect()
        const box   = card.querySelector(".split-right > .mt-2")
        const rows  = [ ...card.querySelectorAll(".prioritise-item") ]
        const last  = rows[rows.length - 1]
        const lr    = last.getBoundingClientRect()
        // Is the last row actually the thing at that point, or is something
        // painted over it? Position is not reachability.
        const hit = document.elementFromPoint(lr.left + lr.width / 2, lr.top + lr.height / 2)
        return {
          type: card.dataset.cardType,
          rows: rows.length,
          clearance: Math.round(pills.top - lr.bottom),
          over: Math.round(box.scrollHeight - box.clientHeight),
          scrollable: box.classList.contains("is-scrollable"),
          reachable: !!hit && (hit === last || last.contains(hit)),
          hitWas: hit ? String(hit.className || hit.tagName).slice(0, 40) : "nothing"
        }
      })()
    JS
  end

  UPRIGHT.each do |name, (w, h)|
    test "every option is on screen and reachable on a #{name}" do
      open_at(w, h)
      r = fit_report

      assert_equal "prioritise", r["type"]
      assert_equal OPTIONS.size, r["rows"]

      assert_operator r["over"], :<=, 1,
                      "the list overflows its box by #{r['over']}px on a #{name}. On any other " \
                      "card type that would just mean scrolling; here the rows are drag targets " \
                      "at touch-action: none, so a finger cannot scroll it and those pixels are " \
                      "options nobody can reach. The card has to be big enough instead — which " \
                      "is what dropping the hero strip is for."
      assert_operator r["clearance"], :>=, CLEAR_PX,
                      "the last option's bottom is #{r['clearance']}px from the floating " \
                      "controls on a #{name} (negative means behind them). This is the owner's " \
                      "screenshot exactly: 'Better facilities' half-covered by Back and Next."
      assert r["reachable"],
             "the last option is positioned clear of the pills but something is painted over " \
             "it (#{r['hitWas']}) — it still cannot be dragged."
    end
  end

  # The list no longer scrolls, so it must not claim to. The cue is a fade at
  # the box's bottom edge plus a runway that lets the last row clear the
  # pills — meaningful on a scroller, a lie on a list that cannot move.
  test "a list that fits shows no scroll cue" do
    open_at(*UPRIGHT["iPhone 15"])

    assert_not fit_report["scrollable"],
               "the answer box is marked is-scrollable while its content fits. The class is not " \
               "passive — it hangs a negative-margin runway off the box — so a false positive " \
               "lets the list bleed under the controls for no reason."
  end
end
