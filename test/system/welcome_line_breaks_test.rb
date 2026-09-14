require "application_system_test_case"

# A creator's line breaks survive the trip: editor → save → reload → player.
#
# They did not. Enter in a contenteditable wraps each line in a <div>, and the
# autosave serialiser captured textContent — which joins block boundaries with
# NOTHING. A welcome card written as three paragraphs came back from reload as
# one lump ("Welcome to the EFA26 survey!Help us learn…Thank you!" — Feedback
# 17's screenshots, side by side). The rich-text layer would have kept the
# markup, but its gate only counts b/i/u/span — text whose only "formatting"
# is line breaks never qualified.
#
# The fix has two halves and each has a test here: innerText capture (yields
# \n at block boundaries) with white-space: pre-line rendering it; and, for
# text that is formatted AND broken, <div> boundaries normalised to <br> in
# the html layer before the sanitiser — which strips <div> but allows <br> —
# would have joined the lines all over again.
class WelcomeLineBreaksTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "lb-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Lb", email_address: "lb-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Breaks", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "cid" => "w",
          "text" => "Welcome to the EFA26 survey!",
          "description" => "Help us learn from your experiences.\n\nThank you!" }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # ── The capture ───────────────────────────────────────────────────────────

  test "the serialiser keeps the breaks a creator typed" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Welcome to the EFA26 survey!"

    # assert_text passes on the server-rendered HTML, which can be BEFORE
    # Stimulus connects — the controller lookup below returned null in that
    # window. Wait for the instance, not just the markup.
    connected = 20.times.any? do
      sleep 0.25
      page.evaluate_script(<<~JS)
        (() => {
          const app  = window.Stimulus || window.application
          const root = document.querySelector('[data-controller~="survey-editor"]')
          return !!(app && root && app.getControllerForElementAndIdentifier(root, "survey-editor"))
        })()
      JS
    end
    assert connected, "the survey-editor controller never connected"

    read = page.evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="survey-editor"]')
        const ctl  = app.getControllerForElementAndIdentifier(root, "survey-editor")
        const card = document.querySelector("[data-card-cid='w']")
        const title = card.querySelector(".q-title")

        // What Enter actually produces in a contenteditable: line-per-<div>,
        // an empty <div><br></div> for a blank line. This is the exact DOM
        // from the owner's before-screenshot.
        title.innerHTML = "<div>Welcome to the EFA26 survey!</div><div><br></div><div>Help us learn.</div>"
        const plain = ctl._readCard(card)

        // The formatted-AND-broken case: bold engages the html layer, whose
        // sanitiser strips <div> while keeping its content — so the layer has
        // to carry the breaks as <br> or they are joined all over again.
        title.innerHTML = "<div><b>Welcome!</b></div><div>Help us learn.</div>"
        const rich = ctl._readCard(card)

        return { plainText: plain.text, richHtml: rich.text_html }
      })()
    JS

    assert_equal "Welcome to the EFA26 survey!\n\nHelp us learn.", read["plainText"],
                 "the serialiser read #{read['plainText'].inspect}. textContent joins " \
                 "contenteditable <div> blocks with nothing — three paragraphs come back " \
                 "from reload as one lump. innerText is the capture that keeps the \\n."
    assert_includes read["richHtml"].to_s, "<br>",
                    "the html layer carries no <br> for a broken, formatted text " \
                    "(#{read['richHtml'].inspect}). The sanitiser strips <div> and keeps its " \
                    "content, so without the boundary normalisation the FORMATTED version of " \
                    "this bug survives the plain-text fix."
    refute_includes read["richHtml"].to_s, "<div",
                    "raw <div>s in the stored html layer — the sanitiser will remove them " \
                    "and the parity-tested allowlist does not admit them; boundaries must be " \
                    "normalised to <br> at capture."
  end

  # ── The render ────────────────────────────────────────────────────────────

  test "stored breaks render as breaks in the player" do
    page.driver.browser.resize(width: 393, height: 768)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    assert_selector ".preview-card.active .q-subtitle", wait: 5

    r = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(".preview-card.active .q-subtitle")
        return { ws: getComputedStyle(el).whiteSpace, rendered: el.innerText }
      })()
    JS
    page.driver.browser.resize(width: 1280, height: 900)

    assert_equal "pre-line", r["ws"],
                 ".q-subtitle is #{r['ws']} — without pre-line the stored \\n collapses to a " \
                 "space and the capture fix changes nothing a respondent can see."
    assert_includes r["rendered"], "\n",
                    "the description renders as one line (#{r['rendered'].inspect}). " \
                    "innerText reflects RENDERED line boxes, so this asserts the storage and " \
                    "the CSS together: the paragraph break the creator typed is the paragraph " \
                    "break the respondent reads."
  end

  # ── Body copy on a card that has none yet ─────────────────────────────────
  #
  # "I would also consider here the main header in current font size, and the
  #  remainder body copy in a smaller font, as per enterprise, fully editable
  #  as all text is in the editor."
  #
  # Both sizes already existed — .q-title and .q-subtitle — and so did the
  # storage. What did not exist was a way to START using them: the subtitle was
  # rendered only when the card already had a description, and the node IS the
  # field (the serialiser reads this element), so a front card with only a
  # heading had nowhere to type body copy. Every line a creator wrote therefore
  # went into the heading, at heading size, which is exactly what the screenshot
  # shows.
  # A DRAFT by default: a live Verto's editor is covered by the live-warning
  # overlay and its deck is edit-locked server-side, so the editor half of this
  # has to happen before the Verto goes out. publish! is the other half.
  def heading_only_survey
    @org.surveys.create!(
      title: "Kick off", theme: "Football", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "cid" => "k", "text" => "KICK OFF" },
        { "type" => "yes_no", "cid" => "q", "text" => "Enjoying it?", "options" => %w[Yes No] }
      ]
    )
  end

  def publish!(survey)
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey
  end

  test "a welcome card with only a heading still offers a body box in the editor" do
    survey = heading_only_survey
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner
    assert_text "KICK OFF"

    box = find("[data-card-cid='k'] .q-subtitle")
    assert_equal "true", box["contenteditable"]
    assert_equal "", box.text.strip, "the box has to start empty or the placeholder cannot show"
    assert_equal I18n.t("card.body_placeholder"), box["data-placeholder"]

    # The placeholder is drawn, not typed: an :empty::before, so it is never
    # read back as the creator's words.
    assert_equal I18n.t("card.body_placeholder"), page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector("[data-card-cid='k'] .q-subtitle"), "::before")
        .content.replace(/^"|"$/g, "")
    JS
  end

  test "body copy typed into that box saves, reloads, and renders at the smaller size" do
    survey = heading_only_survey
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner
    assert_text "KICK OFF"

    box = find("[data-card-cid='k'] .q-subtitle")
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' }); arguments[0].focus()", box)
    press_keys("For three minutes, football is yours.")

    stored = nil
    30.times do
      stored = survey.reload.cards.first["description"]
      break if stored.present?
      sleep 0.5
    end
    assert_equal "For three minutes, football is yours.", stored,
                 "the body copy never reached the deck — the serialiser reads this node, so an " \
                 "absent one is a field that silently reverts"
    assert_equal "KICK OFF", survey.reload.cards.first["text"],
                 "the heading was rewritten by body copy going into the wrong field"

    # And the two sizes a respondent actually meets, on a phone.
    publish!(survey)
    page.driver.browser.resize(width: 393, height: 660)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    assert_selector ".preview-card.active .q-subtitle", text: "For three minutes", wait: 5

    sizes = page.evaluate_script(<<~JS)
      (() => {
        const px = (sel) => parseFloat(getComputedStyle(
          document.querySelector(".preview-card.active " + sel)).fontSize)
        return { title: px(".q-title"), sub: px(".q-subtitle") }
      })()
    JS
    page.driver.browser.resize(width: 1280, height: 900)

    assert_operator sizes["title"], :>, sizes["sub"] + 6,
                    "the heading is #{sizes['title']}px and the body #{sizes['sub']}px — the whole " \
                    "point is that the body reads as body copy rather than more heading"
  end

  # The player must not gain an empty box just because the editor has one.
  test "a card with no body copy draws no subtitle for a respondent" do
    survey = publish!(heading_only_survey)
    page.driver.browser.resize(width: 393, height: 660)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    assert_selector ".preview-card.active .q-title", text: "KICK OFF", wait: 5

    assert page.has_no_css?(".preview-card.active .q-subtitle", visible: true, wait: 2),
           "an empty body box on the player is a gap under the heading with nothing in it"
    page.driver.browser.resize(width: 1280, height: 900)
  end
end
