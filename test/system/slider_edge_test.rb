require "application_system_test_case"

# The slider's thumb has to stay out of the browser's edge back-swipe strip —
# roughly the outer 20px, where a drag that STARTS there is claimed by the OS
# as "go back" and never reaches the page. `touch-action: none` cannot help:
# the edge swipe is a system gesture, not one a page may claim. The only fix
# available is to stop putting a control there.
#
# WHAT THIS PINS, AND WHY IT IS THE EDGE AND NOT THE CENTRE. The first version
# of this fix inset the track by 26px and was measured at the thumb's CENTRE,
# which duly moved to a comfortable 45px. But the thumb is 52px wide and
# translate(-50%), so at either extreme its outer edge is 26px further out than
# its centre — landing at exactly the panel's own --play-pad-x, which clamps
# down to 16px below a 375px screen. Measured then: 20px of clearance on an
# iPhone 15, 19 on an SE, 16 on a 320 and 16 on a folded phone. A finger
# reaching for the visible left of the thumb was still starting inside the
# strip.
#
# So this measures the rectangle a finger can actually touch, at both extremes,
# on the narrow phones the earlier pass never ran.
class SliderEdgeTest < ApplicationSystemTestCase
  # The strip is ~20px on both iOS and Android; 20 is the floor, not the target.
  SAFE_PX = 20

  PHONES = {
    "iPhone 15"  => [ 393, 852 ],
    "iPhone SE"  => [ 375, 667 ],
    "small"      => [ 320, 568 ],
    "Galaxy Fold" => [ 280, 653 ]
  }.freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "sled-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Slider", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hi" },
               { "type" => "range", "cid" => "r1", "text" => "How likely are you to recommend us?",
                 "options" => %w[0 1 2 3 4] } ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  def open_range(width, height)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".preview-card.active .slider-thumb", wait: 5
    sleep 0.3
  end

  # Drive the thumb to each end of the track and report where its own edges
  # land — not where its centre does.
  def thumb_edges
    evaluate_script(<<~JS)
      (() => {
        const card  = document.querySelector(".preview-card.active")
        const track = card.querySelector(".slider-track")
        const thumb = card.querySelector(".slider-thumb")
        const tr = track.getBoundingClientRect()
        const drive = (x) => {
          for (const type of ["pointerdown", "pointermove", "pointerup"]) {
            track.dispatchEvent(new PointerEvent(type, {
              clientX: x, clientY: tr.top + tr.height / 2,
              bubbles: true, pointerId: 1, isPrimary: true, buttons: 1
            }))
          }
        }
        drive(tr.left + 1)
        const min = thumb.getBoundingClientRect()
        drive(tr.right - 1)
        const max = thumb.getBoundingClientRect()
        return {
          minEdge: Math.round(min.left),
          maxEdge: Math.round(window.innerWidth - max.right),
          width:   Math.round(min.width),
          trackWidth: Math.round(tr.width)
        }
      })()
    JS
  end

  PHONES.each do |device, (w, h)|
    test "the slider thumb clears the back-swipe strip at both ends on a #{device}" do
      open_range(w, h)
      e = thumb_edges

      assert_operator e["minEdge"], :>=, SAFE_PX,
                      "#{device}: at the low end the thumb's outer edge is #{e['minEdge']}px " \
                      "from the screen. Inside ~#{SAFE_PX}px the OS claims the drag as a back " \
                      "gesture and the slider never sees it. Measure the EDGE, not the centre " \
                      "— the thumb is #{e['width']}px wide and translate(-50%), so its centre " \
                      "is always #{e['width'] / 2}px more comfortable than it really is."
      assert_operator e["maxEdge"], :>=, SAFE_PX,
                      "#{device}: at the high end the thumb's outer edge is #{e['maxEdge']}px " \
                      "from the screen — this is the end the owner reported ('when I try to " \
                      "scroll from the far right ... it's making me go back a page')."
    end
  end

  # The inset is paid for out of the track, so it cannot grow without limit.
  # The narrowest phone is where that bill lands.
  test "buying that clearance leaves a usable track on the narrowest phone" do
    open_range(*PHONES["Galaxy Fold"])
    e = thumb_edges

    assert_operator e["trackWidth"], :>=, 150,
                    "the track is down to #{e['trackWidth']}px on a Fold. Past a point, " \
                    "insetting further to dodge the edge gesture makes the control itself " \
                    "unusable — that is the trade this number holds."
  end
end
