require "test_helper"

class LiveVertoLockTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Like it?", "options" => [ "Yes", "No" ] }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "lock-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "lock-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @live  = @org.surveys.create!(title: "Live", theme: "Live", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                  publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    @draft = @org.surveys.create!(title: "Draft", theme: "Draft", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup))
  end

  def patch_cards(survey, text)
    patch survey_path(survey),
          params: { cards: [ { "type" => "open_ended", "text" => text } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
  end

  test "live Vertos reject every content mutation" do
    original = @live.cards

    patch_cards(@live, "sneaky edit")
    assert_response :locked
    assert_equal original, @live.reload.cards, "cards must be untouched"

    post generate_survey_card_path(@live)
    assert_response :locked

    post render_survey_card_path(@live), params: { "type" => "yes_no", "text" => "x" }.to_json,
                                         headers: { "Content-Type" => "application/json" }
    assert_response :locked

    post shuffle_survey_assets_path(@live)
    assert_redirected_to survey_path(@live)
    assert_equal original, @live.reload.cards
  end

  test "drafts still save normally" do
    patch_cards(@draft, "legit edit")
    assert_response :success
    assert_equal "legit edit", @draft.reload.cards.first["text"]
  end

  test "the live editor is locked: bar shown, edit affordances gone" do
    get survey_path(@live)
    assert_response :success
    assert_match "questions are locked", response.body
    assert_match "editor-feed-locked", response.body
    refute_match "add-question#open", response.body, "add-question trigger must be hidden"
    refute_match "shuffle_assets", response.body, "shuffle must be hidden"
  end

  test "the draft editor is not locked" do
    get survey_path(@draft)
    assert_response :success
    refute_match "editor-feed-locked", response.body
    assert_match "add-question#open", response.body
  end

  test "publish buttons warn that questions lock" do
    get survey_path(@draft)
    assert_match "locked and can&#39;t be edited", response.body

    get root_path
    assert_match "locked and can&#39;t be edited", response.body, "dashboard publish needs the confirm too"
  end

  test "live settings remain editable" do
    post survey_settings_path(@live), params: { show_results_comparison: "1", compare_note: "still editable" }
    assert_redirected_to survey_path(@live)
    assert @live.reload.show_results_comparison
    assert_equal "still editable", @live.compare_note
  end
end
