require "application_system_test_case"

# The save status says what the server actually did.
#
# Every silent repair on save — a dropped image, a second welcome card removed,
# a consent gate moved — came back as one sentence: "Saved, but an image didn't
# stick — check and re-upload it." A creator whose deck had two welcome cards
# was told, on every autosave, to re-upload an image that was fine.
class SaveWarningMessageTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "swm-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Swm", email_address: "swm-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  # Created directly, so the deck can hold what the editor's save path would
  # never let through — that is exactly the state these tests are about.
  def survey_with(cards)
    @org.surveys.create!(
      title: "Warn", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: cards
    )
  end

  def edit_title_of(cid, text)
    title = find("[data-card-cid='#{cid}'] .q-title[contenteditable]")
    title.click
    title.send_keys(text)
  end

  test "a dropped duplicate card is reported as that, not as an image that didn't stick" do
    # Two welcome cards: nothing stops a deck being CREATED this way (the
    # single-welcome rule runs on the editor's save path), so the first
    # autosave drops the second and reports duplicate_welcome.
    survey = survey_with([
      { "type" => "welcome_card", "cid" => "w1", "text" => "Hello there" },
      { "type" => "welcome_card", "cid" => "w2", "text" => "Hello again" },
      { "type" => "yes_no", "cid" => "y1", "text" => "Ready?", "options" => [ "Yes", "No" ] }
    ])
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner
    assert_text "Ready?"

    edit_title_of("y1", " now")

    assert_selector "[data-survey-editor-target='status']",
                    text: I18n.t("js.editor.save_warning_duplicate"), wait: 10
    assert_no_selector "[data-survey-editor-target='status']", text: /image/i
    assert_equal %w[welcome_card yes_no], survey.reload.cards.map { |c| c["type"] },
                 "the second welcome card should have been dropped by the save the pill reported"
  end

  # The pill names the card, and the page stops showing the picture the server
  # refused. Reported by a creator who had just uploaded an image that saved
  # fine: the warning was about ANOTHER card's older image, which the editor
  # kept on screen — looking saved — and re-sent, re-dropped and re-warned
  # about on every autosave until a reload.
  test "a dropped card image is named by its card number and taken off the page" do
    # A brand-library path with no image extension — the shape an asset stored
    # before storable_filename existed still has: pickable once, refused by the
    # sanitiser ever after. Same-origin, so the editor paints it without a
    # fetch leaving the test server.
    survey = survey_with([
      { "type" => "welcome_card", "cid" => "w1", "text" => "Hello there" },
      { "type" => "yes_no", "cid" => "y1", "text" => "Ready?", "options" => [ "Yes", "No" ] },
      { "type" => "yes_no", "cid" => "y2", "text" => "Sure?", "options" => [ "Yes", "No" ],
        "image" => "/rails/active_storage/blobs/redirect/eyJfcmFpbHMi--abc123/company-logo" }
    ])
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner
    assert_text "Sure?"
    assert_selector "[data-card-cid='y2'] .split-left-img", visible: :all

    edit_title_of("y1", " now")

    assert_selector "[data-survey-editor-target='status']",
                    text: I18n.t("js.editor.save_warning_card", n: 3), wait: 10
    # The refused picture must leave the page, or the next autosave re-sends it.
    assert_selector "[data-card-cid='y2'][data-card-image='']"
    assert_no_selector "[data-card-cid='y2'] .split-left-img", visible: :all
    assert_nil survey.reload.cards.find { |c| c["cid"] == "y2" }["image"]

    # The next edit sends what the server holds, and the pill says so.
    edit_title_of("y1", " please")
    assert_selector "[data-survey-editor-target='status']", text: /\ASaved \d/, wait: 10
    assert_no_selector "[data-survey-editor-target='status']", text: /stick/
  end
end
