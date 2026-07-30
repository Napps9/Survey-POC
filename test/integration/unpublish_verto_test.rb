require "test_helper"

# Publishing used to be one-way: nothing ever cleared publish_token, so a live
# Verto stayed live forever. Unpublishing stamps unpublished_at and KEEPS the
# token, so the same /play link (and any printed QR) comes back on re-publish.
#
# The important rule: unpublishing must never become a back door to editing a
# deck people have already answered, because answers are keyed by card index.
class UnpublishVertoTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "unp-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "unp-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def sign_in!
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def live_survey
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: CARDS,
                         publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def answer!(survey)
    survey.responses.create!(session_token: SecureRandom.uuid, answers: { "1" => "Yes" },
                             answered: true, status: "completed")
  end

  # ── State predicates ──────────────────────────────────────────────────────

  test "a live Verto is published, playable and locked for editing" do
    s = live_survey
    assert s.published?
    assert s.playable?
    assert s.editing_locked?
    assert_not s.unpublished?
  end

  test "unpublishing with no responses returns it to an editable draft" do
    s = live_survey
    sign_in!
    post unpublish_survey_path(s)
    s.reload

    assert_not s.published?
    assert_not s.playable?
    assert s.unpublished?
    assert s.reverted_to_draft?
    assert_not s.closed?
    assert_not s.editing_locked?, "nothing has been answered, so there is nothing to misalign"
    # The link is reserved, not destroyed.
    assert s.publish_token.present?
  end

  test "unpublishing after responses closes it and keeps the deck frozen" do
    s = live_survey
    answer!(s)
    sign_in!
    post unpublish_survey_path(s)
    s.reload

    assert_not s.published?
    assert s.unpublished?
    assert s.closed?
    assert_not s.reverted_to_draft?
    assert s.editing_locked?, "answers are keyed by card index — the deck can never move again"
  end

  # ── The editing boundary ──────────────────────────────────────────────────

  test "a closed Verto still refuses deck edits" do
    s = live_survey
    answer!(s)
    s.update!(unpublished_at: Time.current)
    sign_in!

    patch survey_path(s), params: { cards: [ CARDS.first ] }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :locked
    assert_equal 2, s.reload.cards.size
  end

  test "a Verto unpublished before anyone answered can be edited again" do
    s = live_survey
    sign_in!
    post unpublish_survey_path(s)

    patch survey_path(s), params: { title: "Edited after unpublish", cards: CARDS }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal "Edited after unpublish", s.reload.title
  end

  # ── The player ────────────────────────────────────────────────────────────

  test "the player stops serving an unpublished Verto" do
    s = live_survey
    token = s.publish_token
    get play_survey_path(token)
    assert_response :success

    s.update!(unpublished_at: Time.current)
    get play_survey_path(token)
    assert_response :gone
    # The branded explainer, not a bare error — and not the archived-forever copy.
    assert_select "h1", text: I18n.t("oops.unpublished_title")
    assert_select "h1", text: I18n.t("oops.gone_title"), count: 0
  end

  test "an unpublished Verto stops accepting responses" do
    s = live_survey
    token = s.publish_token
    s.update!(unpublished_at: Time.current)

    post progress_survey_path(token), params: { session_token: SecureRandom.uuid, answers: { "1" => "Yes" } }.to_json,
                                      headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :gone

    post submit_survey_path(token), params: { session_token: SecureRandom.uuid, answers: { "1" => "Yes" } }.to_json,
                                    headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :gone
    assert_equal 0, s.responses.count
  end

  test "a custom slug does not route around the unpublished boundary" do
    s = live_survey
    s.update!(slug: "my-verto-#{SecureRandom.hex(3)}")
    get play_survey_path(s.slug)
    assert_response :success

    s.update!(unpublished_at: Time.current)
    get play_survey_path(s.slug)
    assert_response :gone
  end

  # ── Re-publishing ─────────────────────────────────────────────────────────

  test "re-publishing restores the original link" do
    s = live_survey
    original = s.publish_token
    sign_in!
    post unpublish_survey_path(s)
    post publish_survey_path(s)
    s.reload

    assert s.published?
    assert_nil s.unpublished_at
    assert_equal original, s.publish_token, "a reprinted QR code has to keep working"

    get play_survey_path(original)
    assert_response :success
  end

  test "unpublishing something that isn't live is refused" do
    s = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                             default_locale: "en", locales: [ "en" ], cards: CARDS)
    sign_in!
    post unpublish_survey_path(s)
    assert_redirected_to survey_path(s)
    assert_nil s.reload.unpublished_at
  end

  test "another organisation cannot unpublish your Verto" do
    s = live_survey
    other = User.create!(name: "X", email_address: "other-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    other_org = Organisation.create!(name: "X", slug: "x-#{SecureRandom.hex(3)}")
    other_org.memberships.create!(user: other, role: "admin")
    post session_path, params: { email_address: other.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    # set_survey scopes to Current.organisation, so this is a 404 — the Verto
    # simply isn't theirs to find.
    post unpublish_survey_path(s)
    assert_response :not_found
    assert s.reload.published?
  end

  # ── Where it surfaces ─────────────────────────────────────────────────────

  test "the editor offers unpublish while live, and re-publish once not" do
    s = live_survey
    sign_in!
    get survey_path(s)
    assert_select "form[action=?]", unpublish_survey_path(s)

    s.update!(unpublished_at: Time.current)
    get survey_path(s)
    assert_select "form[action=?]", unpublish_survey_path(s), false
    assert_select "form[action=?]", publish_survey_path(s)
  end

  test "the dashboard shows Closed for an unpublished Verto with responses" do
    s = live_survey
    answer!(s)
    s.update!(unpublished_at: Time.current)
    sign_in!

    get root_path
    assert_response :success
    assert_match I18n.t("dashboard_card.badge_closed"), response.body
  end

  test "the dashboard shows Draft again when nobody answered" do
    s = live_survey
    s.update!(unpublished_at: Time.current)
    sign_in!

    get root_path
    assert_response :success
    assert_no_match I18n.t("dashboard_card.badge_closed"), response.body
  end
end
