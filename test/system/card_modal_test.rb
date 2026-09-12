require "application_system_test_case"

# The card intro modal, driven through a browser — both halves of it.
#
# The editor half exists for the reason ConsentGateEditorTest does: serialize()
# rebuilds every card from live DOM on every save, so a gap between what the
# creator types and what the serialiser reads is invisible to any test that
# seeds cards with create!. The modal's words live in contenteditable nodes,
# which is exactly that shape.
#
# The player half is here because "once per card per run" is a statement about
# navigation, and navigation only exists in the browser.
class CardModalTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "cid" => "w1", "title" => "Hello" },
    { "type" => "yes_no", "cid" => "q1", "text" => "Do you feel safe here?", "options" => %w[Yes No] },
    { "type" => "yes_no", "cid" => "q2", "text" => "Would you recommend it?", "options" => %w[Yes No],
      "modal_title" => "Before you answer this one",
      "modal_body" => "We mean the last twelve months, not your whole time here." },
    # q2 must not be the last card: the player swaps Next for Finish there, and
    # the assertions below are about the modal giving the NAV back, not about
    # which button the last card happens to show.
    { "type" => "yes_no", "cid" => "q3", "text" => "Anything else?", "options" => %w[Yes No] }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "cmo-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Cm", email_address: "cmo-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Modals", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Do you feel safe here?"
  end

  def card_for(cid) = @survey.reload.cards.find { |c| c["cid"] == cid }

  def wait_until_saved(&predicate)
    Timeout.timeout(15) { sleep 0.25 until predicate.call }
  end

  # ── Editor ────────────────────────────────────────────────────────────────

  test "a modal added in the rail and typed into survives the round trip" do
    open_editor

    find("[data-card-cid='q1'] [data-role='card-modal-btn']").click
    assert_selector "[data-card-cid='q1'] [data-role='card-modal-title']", visible: true

    execute_script(<<~JS)
      const card  = document.querySelector("[data-card-cid='q1']")
      const title = card.querySelector("[data-role='card-modal-title']")
      const body  = card.querySelector("[data-role='card-modal-body']")
      title.textContent = "Heads up"
      title.dispatchEvent(new Event("input", { bubbles: true }))
      body.textContent = "Think about the street you live on."
      body.dispatchEvent(new Event("input", { bubbles: true }))
      body.blur()
    JS

    wait_until_saved { card_for("q1")["modal_title"] == "Heads up" }
    assert_equal "Think about the street you live on.", card_for("q1")["modal_body"]
  end

  # The other half of the same risk: the serialiser must not DROP a modal it
  # was never asked to touch. An edit anywhere in the deck rewrites every card.
  test "editing an unrelated card leaves another card's modal alone" do
    open_editor

    execute_script(<<~JS)
      const q = document.querySelector("[data-card-cid='q1'] .q-title")
      q.textContent = "Do you feel safe around here?"
      q.dispatchEvent(new Event("input", { bubbles: true }))
      q.blur()
    JS

    wait_until_saved { card_for("q1")["text"].to_s.include?("around here") }
    assert_equal "Before you answer this one", card_for("q2")["modal_title"],
                 "an autosave from an unrelated edit dropped a modal the creator never touched"
    assert_equal "We mean the last twelve months, not your whole time here.",
                 card_for("q2")["modal_body"]
  end

  test "the replica rests folded, so the question underneath stays editable" do
    open_editor

    layer = find("[data-card-cid='q2'] [data-role='card-modal']")
    assert layer[:class].include?("is-folded"), "an unfolded replica sits over the question"
    # Its heading, not the generic label — folded, the bar is the preview.
    assert_equal "Before you answer this one",
                 find("[data-card-cid='q2'] [data-role='card-modal-chrome-label']").text

    find("[data-card-cid='q2'] .card-modal-fold").click
    assert_selector "[data-card-cid='q2'] [data-role='card-modal-body']", visible: true
  end

  test "removing asks once, then takes the words with it" do
    open_editor
    find("[data-card-cid='q2'] .card-modal-fold").click

    remove = find("[data-card-cid='q2'] .card-modal-remove")
    remove.click
    assert_equal I18n.t("editor.modal_remove_confirm"), remove.text,
                 "removing clears text the browser's own undo cannot put back, so it arms first"
    remove.click

    wait_until_saved { !card_for("q2").key?("modal_title") }
    refute card_for("q2").key?("modal_body")
    # aria-pressed, not the label: selecting a card opens the right panel,
    # which collapses the rail to icons and hides every .rail-label.
    assert_selector "[data-card-cid='q2'] [data-role='card-modal-btn'][aria-pressed='false']"
  end

  # The Preview overlay clones the editor's DOM and walks it with its own
  # controller, so the modal needs its whole behaviour re-established there.
  # Get it wrong and "preview as a respondent" shows either no pop-up at all or
  # the creator's editable replica with a Remove button in it.
  test "Preview shows the modal the way a respondent gets it" do
    open_editor
    execute_script("document.querySelector(\"[data-action='click->preview-verto#open']\").click()")

    overlay = find("[data-preview-verto-target='overlay']")
    # Not on the welcome card — the editor renders a replica on every card, and
    # the clone has to drop the ones with no words in them.
    assert_no_selector "[data-preview-verto-target='overlay'] [data-role='card-modal']",
                       visible: true, wait: 2

    overlay.find("[data-preview-verto-target='nextBtn']").click  # -> q1, no modal
    overlay.find("[data-preview-verto-target='nextBtn']").click  # -> q2, the modal

    assert_selector "[data-preview-verto-target='overlay'] [data-role='card-modal']", visible: true
    assert_no_selector "[data-preview-verto-target='overlay'] .card-modal-chrome",
                       visible: :all,
                       wait: 2                                   # no Remove, no fold bar
    overlay.find(".card-modal-cta").click
    assert_no_selector "[data-preview-verto-target='overlay'] [data-role='card-modal']",
                       visible: true
  end

  # ── Player ────────────────────────────────────────────────────────────────

  def play!
    @survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    visit play_survey_path(@survey.publish_token)
    dismiss_cookie_banner
    find(".play-consent-banner .play-consent-agree").click if has_css?(".play-consent-banner", wait: 2)
  end

  test "it opens on arrival, takes the nav with it, and gives it back on dismiss" do
    play!

    assert_no_selector "[data-role='card-modal']", visible: true
    find("[data-player-target='nextBtn']").click   # welcome -> q1
    assert_no_selector "[data-role='card-modal']", visible: true
    find("[data-player-target='nextBtn']").click   # q1 -> q2, the one with a modal

    assert_selector "[data-role='card-modal']", visible: true
    assert_text "We mean the last twelve months, not your whole time here."
    assert_no_selector "[data-player-target='nextBtn']", visible: true,
                       wait: 2                     # one way forward while it is open

    find(".card-modal-cta").click
    assert_no_selector "[data-role='card-modal']", visible: true
    assert_selector "[data-player-target='nextBtn']", visible: true
  end

  test "it interrupts once — going back and forward again finds it shut" do
    play!
    2.times { find("[data-player-target='nextBtn']").click }
    find(".card-modal-cta").click
    assert_no_selector "[data-role='card-modal']", visible: true

    find("[data-player-target='backBtn']").click
    assert_text "Do you feel safe here?"
    find("[data-player-target='nextBtn']").click
    assert_text "Would you recommend it?"

    assert_no_selector "[data-role='card-modal']", visible: true,
                       wait: 2
  end

  test "the pill brings the words back, and only after they have been dismissed" do
    play!
    2.times { find("[data-player-target='nextBtn']").click }
    assert_no_selector "[data-role='card-modal-reopen']", visible: true

    find(".card-modal-cta").click
    find("[data-role='card-modal-reopen']").click
    assert_selector "[data-role='card-modal']", visible: true
    assert_text "We mean the last twelve months, not your whole time here."
  end

  # The consent banner makes the whole deck inert. A modal opened underneath it
  # is a pop-up the respondent can see and cannot dismiss — so it waits, and
  # arrives the moment the deck is live.
  test "a modal on the first card waits for the consent banner" do
    @survey.update!(cards: [
      CARDS[1].merge("modal_title" => "One thing first",
                     "modal_body" => "Answer for your own street."),
      CARDS[3]
    ], consent_text: "We ask about where you live.")
    @survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    visit play_survey_path(@survey.publish_token)
    dismiss_cookie_banner
    assert_selector ".play-consent-banner"
    assert_no_selector "[data-role='card-modal']", visible: true, wait: 2

    find(".play-consent-banner .play-consent-agree").click
    assert_selector "[data-role='card-modal']", visible: true
    assert_text "Answer for your own street."
  end

  test "a reload mid-run does not re-interrupt on a card already read" do
    play!
    2.times { find("[data-player-target='nextBtn']").click }
    find(".card-modal-cta").click
    assert_no_selector "[data-role='card-modal']", visible: true

    visit play_survey_path(@survey.publish_token)
    dismiss_cookie_banner
    find(".play-consent-banner .play-consent-agree").click if has_css?(".play-consent-banner", wait: 2)
    2.times { find("[data-player-target='nextBtn']").click }
    assert_text "Would you recommend it?"

    assert_no_selector "[data-role='card-modal']", visible: true, wait: 2
  end
end
