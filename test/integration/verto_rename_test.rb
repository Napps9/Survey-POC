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

  # BUG-013. The editor's blur guard restored the title from `titleValue` —
  # which the input handler had already overwritten with the blank, so it put
  # the blank back over the blank and the save wiped the name. The server took
  # whatever it was sent. Both halves are fixed; this pins the server half,
  # which is the one that decides what ends up in the column.
  test "a blank title is ignored rather than saved over the name" do
    s = draft(title: "Original name")

    [ "", "   ", "\n\t " ].each do |blank|
      patch survey_path(s), params: { title: blank, cards: s.cards }.to_json,
                            headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :success
      assert_equal "Original name", s.reload.title,
                   "a blank title (#{blank.inspect}) must not overwrite the Verto's name"
    end
  end

  # The blank guard must not swallow a legitimate rename that merely has
  # surrounding whitespace — otherwise it fixes one bug by creating another.
  test "a title with surrounding whitespace still renames" do
    s = draft
    patch survey_path(s), params: { title: "  Padded name  ", cards: s.cards }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal "Padded name", s.reload.title
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

  # ── The theme ─────────────────────────────────────────────────────────────
  # The theme is what respondents call the Verto — the player's tab title, the
  # link preview, the dashboard tile's big line — and nothing could change it
  # after the wizard, so a copy's "(Copy)" was permanent. It is renameable from
  # the same header now, through the same autosave, under the same rules.

  test "the editor renders the theme as an editable field beside the name" do
    s = draft
    get survey_path(s)
    assert_response :success
    assert_select "[data-survey-editor-target='vertoTheme'][contenteditable='true']", text: "Sports"
  end

  test "the autosave payload renames the theme and leaves the name alone" do
    s = draft
    patch survey_path(s), params: { theme: "Sports, wave two", cards: s.cards }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    s.reload
    assert_equal "Sports, wave two", s.theme
    assert_equal "Original name", s.title
  end

  test "a blank theme is ignored rather than saved" do
    s = draft

    [ "", "   ", "\n\t " ].each do |blank|
      patch survey_path(s), params: { theme: blank, cards: s.cards }.to_json,
                            headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :success
      assert_equal "Sports", s.reload.theme,
                   "a blank theme (#{blank.inspect}) must not overwrite the Verto's theme"
    end
  end

  test "a theme is squished to one line and capped at the wizard's length" do
    s = draft
    patch survey_path(s), params: { theme: "  Sports \n and   more  ", cards: s.cards }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal "Sports and more", s.reload.theme

    patch survey_path(s), params: { theme: "x" * (Survey::MAX_THEME + 40), cards: s.cards }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal Survey::MAX_THEME, s.reload.theme.length
  end

  test "the theme is read-only once live, like the name" do
    s = draft
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get survey_path(s)
    assert_response :success
    assert_select "[data-survey-editor-target='vertoTheme']"
    assert_select "[data-survey-editor-target='vertoTheme'][contenteditable='true']", false

    patch survey_path(s), params: { theme: "Nope" }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :locked
    assert_equal "Sports", s.reload.theme
  end

  # The reported flow, end to end: copy a Verto, rename it, send the test link.
  # The recipient's tab title and link preview read the new theme, and the
  # original is untouched.
  test "renaming a copy's theme is what its test link shows" do
    original = draft(title: "Sports check", theme: "Sports")
    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    patch survey_path(copy), params: { theme: "Sports, wave two", cards: copy.cards }.to_json,
                             headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    post test_link_survey_path(copy)
    token = copy.reload.test_token
    delete session_path

    get test_survey_path(token)
    assert_response :success
    assert_select "head title", "Sports, wave two · Playverto"
    assert_select "meta[property='og:title'][content=?]", "Sports, wave two · Playverto"
    assert_select "meta[property='og:image:alt'][content=?]", "Sports, wave two · Playverto"
    assert_equal "Sports", original.reload.theme
  end
end
