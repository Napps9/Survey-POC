require "test_helper"

# Renaming a Verto from the editor. The plumbing already existed — serialize()
# sent `title` and #update accepted it — but nothing ever reassigned the value,
# so there was no field to rename from.
class VertoRenameTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "ren-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ren-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def draft(title: "Original name", theme: "Sports")
    @org.surveys.create!(title: title, theme: theme, audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: CARDS)
  end

  test "the editor renders the name as an editable field, seeded with the title" do
    s = draft
    get survey_path(s)
    assert_response :success
    assert_select "[data-survey-editor-target='vertoTitle'][contenteditable='true']", text: "Original name"
  end

  test "the autosave payload renames the Verto" do
    s = draft
    patch survey_path(s), params: { title: "Renamed in the editor", cards: s.cards }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal "Renamed in the editor", s.reload.title
  end

  # theme is the AI brief's subject and is NOT what the creator renamed.
  test "renaming leaves the theme alone" do
    s = draft
    patch survey_path(s), params: { title: "New name", cards: s.cards }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    s.reload
    assert_equal "New name", s.title
    assert_equal "Sports", s.theme
  end

  # The reported symptom behind this: the dashboard read `theme` first, so a
  # rename appeared to do nothing.
  test "the dashboard tile shows the title, not the theme" do
    draft(title: "What I called it", theme: "Sports")
    get root_path
    assert_response :success
    assert_match "What I called it", response.body
    assert_select "a", text: /Sports/, count: 0
  end

  test "a Verto with no title still falls back to its theme" do
    @org.surveys.create!(title: nil, theme: "Fallback theme", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: CARDS)
    get root_path
    assert_match "Fallback theme", response.body
  end

  # #update rejects any edit to a published Verto (423), so an editable title
  # there would be a field whose saves silently fail.
  test "the name is read-only once live" do
    s = draft
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get survey_path(s)
    assert_response :success
    assert_select "[data-survey-editor-target='vertoTitle']"
    assert_select "[data-survey-editor-target='vertoTitle'][contenteditable='true']", false

    patch survey_path(s), params: { title: "Nope" }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :locked
    assert_equal "Original name", s.reload.title
  end
end
