require "test_helper"

class FormsModeTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def survey_for(org, render_mode: nil)
    attrs = { title: "T", theme: "T", audience_age: "all", key_insight: "x",
              default_locale: "en", locales: [ "en" ], cards: CARDS,
              publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current }
    attrs[:render_mode] = render_mode if render_mode
    org.surveys.create!(attrs)
  end

  test "render_mode defaults to cards and forms_mode? reflects the column" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    s = survey_for(org)
    assert_equal "cards", s.render_mode
    assert_not s.forms_mode?

    s.update!(render_mode: "form")
    assert s.forms_mode?
  end

  test "normalize_render_mode whitelists to a known mode" do
    assert_equal "form", Survey.normalize_render_mode("form")
    assert_equal "cards", Survey.normalize_render_mode("cards")
    assert_equal "cards", Survey.normalize_render_mode("nonsense")
    assert_equal "cards", Survey.normalize_render_mode(nil)
  end

  test "update_settings sets and clears form mode" do
    org = sign_in_org("forms")
    s = survey_for(org)

    post survey_settings_path(s), params: { render_mode: "form" }
    assert_equal "form", s.reload.render_mode
    assert s.forms_mode?

    # The hidden field posts "cards" when the checkbox is unticked.
    post survey_settings_path(s), params: { render_mode: "cards" }
    assert_equal "cards", s.reload.render_mode
    assert_not s.forms_mode?
  end

  test "update_settings rejects an invalid render_mode, keeping cards" do
    org = sign_in_org("forms-bad")
    s = survey_for(org)
    post survey_settings_path(s), params: { render_mode: "haxx" }
    assert_equal "cards", s.reload.render_mode
  end

  test "the player marks a form-mode Verto on its root and still renders its cards" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    s = survey_for(org, render_mode: "form")

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_match(/class="preview-overlay[^"]*forms-mode/, response.body)
    assert_includes response.body, 'data-player-forms-value="true"'
    # Same one-question-at-a-time flow — the question card is still there.
    assert_includes response.body, "Q"
  end

  test "a normal Verto is not marked as form mode" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    s = survey_for(org)

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_no_match(/forms-mode/, response.body)
    assert_includes response.body, 'data-player-forms-value="false"'
  end
end
