require "application_system_test_case"

# The welcome logo in the EDITOR's phone preview.
#
# The logo floats over the top of the content panel — `position: absolute;
# top: 22px` — which is right on a desktop card, where the panel is 680px tall
# and vertically centred, and wrong on a phone, where the panel is whatever the
# hero left behind and the logo lands on top of the question title.
#
# That was fixed for respondents. It was fixed with a rule scoped to
# `.preview-overlay` inside a phone-width media query, and the editor's device
# preview is neither of those things: it is a desktop-width page with a
# `device-mobile` class on the cards feed, reframing the same editable DOM. So
# the creator went on judging the card in a preview that showed a bug the live
# player no longer had — which is the worst direction for a preview to be wrong
# in, because it invites someone to "fix" something that is already correct.
#
# Capybara rather than a headless script on purpose: driving the editor through
# Playwright fails on actionability here (verified against a control card), and
# this test has to actually click the device picker.
class EditorDevicePreviewLogoTest < ApplicationSystemTestCase
  def setup
    super
    @org = Organisation.create!(name: "Ed", slug: "edlogo-#{SecureRandom.hex(3)}")
    @org.logo.attach(io: StringIO.new(svg), filename: "d.svg", content_type: "image/svg+xml")
    @org.logo_on_light.attach(io: StringIO.new(svg), filename: "l.svg", content_type: "image/svg+xml")
    @user = User.create!(name: "Ed", email_address: "ed-#{SecureRandom.hex(3)}@t.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")

    # A title long enough to reach up toward the logo. A one-word welcome would
    # pass this test on broken CSS simply by not being tall enough to collide.
    @survey = @org.surveys.create!(
      title: "Ed", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "cid" => "w",
                 "text" => "Welcome to the session survey and thanks for taking part today" } ]
    )
  end

  def svg
    %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 48">) +
      %(<rect width="240" height="48" fill="#161B2E"/></svg>)
  end

  def sign_in
    visit new_session_path
    fill_in "email_address", with: @user.email_address
    fill_in "password", with: "verylongpassword"
    click_on(class: "btn-primary", match: :first) rescue find("input[type=submit]").click
    assert_no_selector "input[name=password]", wait: 10
  end

  def logo_vs_title
    page.evaluate_script(<<~JS)
      (() => {
        const card = Array.from(document.querySelectorAll(".survey-card-wrap"))
          .find((c) => c.querySelector(".split-right-logo") && c.querySelector(".q-title"))
        if (!card) return null
        const logo  = card.querySelector(".split-right-logo")
        const title = card.querySelector(".q-title")
        const l = logo.getBoundingClientRect(), t = title.getBoundingClientRect()
        return {
          position: getComputedStyle(logo).position,
          logoBottom: Math.round(l.bottom),
          titleTop:   Math.round(t.top),
          overlaps:   l.bottom > t.top + 1
        }
      })()
    JS
  end

  def switch_device(name)
    find("[data-device='#{name}']").click
    sleep 0.6
  end

  test "the phone preview does not draw the welcome logo over the question" do
    sign_in
    visit survey_path(@survey)
    assert_selector ".survey-card-wrap .split-right-logo", wait: 10

    switch_device("mobile")
    m = logo_vs_title
    assert m, "no welcome card with both a logo and a title on screen"

    assert_equal "static", m["position"],
                 "the logo is still #{m['position']} in the phone frame. The player's fix is " \
                 "scoped to .preview-overlay and a phone-width media query; this frame is a " \
                 "desktop-width page with a device-mobile class, so it needs its own rule."
    assert_not m["overlaps"],
               "the logo's bottom edge is at #{m['logoBottom']} and the title starts at " \
               "#{m['titleTop']} — they are on top of each other, which is what a creator " \
               "sees when they check how the card will look on a phone."
  end

  # The desktop frame must keep the float — this is not a bug there, and
  # flattening it everywhere would be a regression dressed as a fix.
  test "the desktop frame keeps the logo floating above the panel" do
    sign_in
    visit survey_path(@survey)
    assert_selector ".survey-card-wrap .split-right-logo", wait: 10

    switch_device("desktop")
    d = logo_vs_title

    assert_equal "absolute", d["position"],
                 "the desktop card lost its floated logo. The panel is tall and centred " \
                 "there, so the float is correct and only the phone frames need the flow."
    assert_not d["overlaps"], "even floated, the desktop logo should clear the title"
  end
end
