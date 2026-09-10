require "application_system_test_case"

# The editor's phone frame has to draw the card the way the phone will.
#
# It cannot inherit the player's mobile rules: those sit inside a media query
# about the VIEWPORT, and the frame is a 390px box on a desktop-width page. So
# they are restated for .device-mobile (device_frame_parity_test holds the two
# blocks together at source level). This is the other half — what the browser
# actually lays out — because the failure that started it was not a missing
# declaration but a card that simply looked wrong: a flat 28% hero on every
# card, including the two card types the live player gives no hero at all.
#
# A creator who designs against that is designing against a phone that does not
# exist, and finds out after publishing.
class EditorMobileParityTest < ApplicationSystemTestCase
  IMG = "https://images.pexels.com/photos/1/pexels-photo-1.jpeg".freeze

  def setup
    super
    @org  = Organisation.create!(name: "Par", slug: "par-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Par", email_address: "par-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Par", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "multiple_choice", "cid" => "pic", "text" => "Which one?",
          "options" => %w[Alpha Bravo Charlie], "image" => IMG },
        { "type" => "nps", "cid" => "nps", "text" => "How likely?" }
      ]
    )
  end

  def open_phone_frame
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Which one?"
    find(".device-toggle-btn[data-device='mobile']").click
    # The frame is a CSS class swap, not a render — one paint is enough, but
    # :has() re-evaluation plus the hero's own height needs the next frame.
    assert_selector ".device-mobile", wait: 5
  end

  def geometry(cid)
    evaluate_script(<<~JS)
      (() => {
        const wrap  = document.querySelector("[data-card-cid='#{cid}']")
        const card  = wrap.querySelector(".split-card")
        const left  = wrap.querySelector(".split-left")
        const right = wrap.querySelector(".split-right")
        const c = card.getBoundingClientRect(), r = right.getBoundingClientRect()
        return {
          cardH:     Math.round(c.height),
          leftDisplay: getComputedStyle(left).display,
          heroH:     Math.round(left.getBoundingClientRect().height),
          panelTop:  Math.round(r.top - c.top),
          titleSize: parseFloat(getComputedStyle(wrap.querySelector(".q-title")).fontSize)
        }
      })()
    JS
  end

  # 45/55 is the player's number, and it is one number in two halves — see the
  # long comment above --play-hero-h. A frame that draws its own share is the
  # 28% band this replaced.
  test "a card with a picture gets the phone's 45% hero, not a band of its own" do
    open_phone_frame
    g = geometry("pic")

    assert_equal "block", g["leftDisplay"], "the hero strip is not being drawn at all"
    share = g["heroH"].to_f / g["cardH"]
    assert_in_delta 0.45, share, 0.03,
                    "the phone frame gives the hero #{(share * 100).round(1)}% of the card. The " \
                    "player gives 45%, so the creator is framing the photograph against the " \
                    "wrong crop."
  end

  # NPS is one of the three types whose ANSWER needs the whole card — the liquid
  # container is a tall vessel with a column of digits beside it — so the player
  # drops its hero strip entirely. The frame drew one anyway, which is how a
  # creator ends up choosing a picture for a card that will never show one.
  test "an NPS card has no hero strip in the phone frame, exactly as on a phone" do
    open_phone_frame
    g = geometry("nps")

    assert_equal "contents", g["leftDisplay"],
                 "the NPS card is drawing a hero strip in the phone frame. The live player " \
                 "gives it none — its answer needs the card — so this preview is showing the " \
                 "creator a card that cannot ship."
    assert_operator g["panelTop"], :<, 40,
                    "the answer panel starts #{g['panelTop']}px down the frame, so something " \
                    "is still holding a strip open above it"
  end

  # "Content and images can be lost before the question and answers change."
  # The type tokens are flat floors on a phone and the frame had none of them,
  # so the creator judged their copy at the desktop card's sizes.
  test "the phone frame sets type and touch targets at the phone's sizes" do
    open_phone_frame

    assert_operator geometry("pic")["titleSize"], :>=, 25.0,
                    "the question is drawn at the desktop card's size in the phone frame"

    rows = evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("[data-card-cid='pic'] .pick-item"))
           .map(el => Math.round(el.getBoundingClientRect().height))
    JS
    assert rows.any?, "no option rows found on the picture card"
    rows.each do |h|
      assert_operator h, :>=, 44,
                      "an option row is #{h}px in the phone frame — below the 44px touch " \
                      "minimum the player holds, on the view whose whole job is showing the " \
                      "creator what a finger will meet"
    end
  end
end
