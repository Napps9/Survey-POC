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
    # Two welcome cards: nothing stops a deck being CREATED this way (the
    # single-welcome rule runs on the editor's save path), so the first
    # autosave drops the second and reports duplicate_welcome.
    @survey = @org.surveys.create!(
      title: "Warn", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "cid" => "w1", "text" => "Hello there" },
        { "type" => "welcome_card", "cid" => "w2", "text" => "Hello again" },
        { "type" => "yes_no", "cid" => "y1", "text" => "Ready?", "options" => [ "Yes", "No" ] }
      ]
    )
  end

  test "a dropped duplicate card is reported as that, not as an image that didn't stick" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Ready?"

    title = find("[data-card-cid='y1'] .q-title[contenteditable]")
    title.click
    title.send_keys(" now")

    assert_selector "[data-survey-editor-target='status']",
                    text: I18n.t("js.editor.save_warning_duplicate"), wait: 10
    assert_no_selector "[data-survey-editor-target='status']", text: /image/i
    assert_equal %w[welcome_card yes_no], @survey.reload.cards.map { |c| c["type"] },
                 "the second welcome card should have been dropped by the save the pill reported"
  end
end
