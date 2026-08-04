require "application_system_test_case"

# Device preview (tablet/mobile) reframes only the CARD — the per-card chrome
# row (Card N pill, why-CTA, traffic light, reorder, duplicate, delete) must
# stay outside the bezel at desktop width, same as desktop preview. The first
# version framed the whole .survey-card-wrap, which squeezed every CTA inside
# the phone; geometry is the only honest way to assert it stays fixed.
class DeviceFrameChromeTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Hello" },
    { "type" => "yes_no", "cid" => "c1", "text" => "A question?", "options" => %w[Yes No] }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Frames", slug: "df-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Df", email_address: "df-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "Frames", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
  end

  %w[mobile tablet].each do |device|
    test "the card chrome stays outside the #{device} frame" do
      sign_in_as(@user)
      visit survey_path(@survey)
      dismiss_cookie_banner
      assert_text "A question?"

      find(".device-toggle-btn[data-device='#{device}']").click

      geometry = evaluate_script(<<~JS)
        (() => {
          const wrap  = document.querySelector("[data-card-cid='c1']")
          const frame = wrap.querySelector(".split-card")
          const pill  = wrap.querySelector(".card-num-pill")
          const del   = wrap.querySelector(".card-delete-btn")
          const w = wrap.getBoundingClientRect(), f = frame.getBoundingClientRect(),
                p = pill.getBoundingClientRect(), d = del.getBoundingClientRect()
          return {
            frameNarrowerThanWrap: f.width < w.width - 100,
            chromeBesideFrame: p.right <= f.left && d.right <= f.left
          }
        })()
      JS

      assert geometry["frameNarrowerThanWrap"],
             "the bezel is as wide as the wrap — the frame is back on the wrap itself"
      assert geometry["chromeBesideFrame"],
             "the CTA rail must sit fully outside the device frame, on its inline-start side"
    end
  end
end
