require "test_helper"

# The "Submit your Verto data" picker: a batch of opt-ins with question-set
# granularity. What matters here is that everything the form claims is
# re-derived server-side — org scoping, the eligibility bar, and the set ids —
# and that one submission produces exactly one team notification and one
# submitter confirmation.
class AskSubmissionsTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  def setup
    @org   = Organisation.create!(name: "Anglo American Foundation", slug: "as-#{SecureRandom.hex(3)}")
    @admin = User.create!(name: "Ada Admin", email_address: "as-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @admin.verify_email!
    @org.memberships.create!(user: @admin, role: "admin")
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect!
  end

  def build_survey(published: true, responses: CorpusEntry::SUBMISSION_MIN_RESPONSES, cards: nil)
    cards ||= [
      { "type" => "multiple_choice", "cid" => "c_own", "text" => "How happy are you?",
        "options" => %w[Happy Neutral] },
      { "type" => "multiple_choice", "cid" => "c_common", "text" => "How safe do you feel?",
        "options" => %w[Safe Unsafe], "common_question_set_id" => 77, "common_question_id" => 770 }
    ]
    survey = @org.surveys.create!(
      title: "Wellbeing Check-in", theme: "Well-being", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards,
      **(published ? { publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current } : {})
    )
    responses.times do
      survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                               answers: { "0" => { "value" => "Happy" } })
    end
    survey
  end

  test "a whole-Verto submission opts in with an empty scope and sends both emails" do
    survey = build_survey
    sign_in @admin

    assert_enqueued_emails 2 do
      post ask_submissions_path, params: {
        vertos: { survey.id => { own: "1", set_ids: [ "77" ] } }
      }
    end

    assert_redirected_to ask_path(submitted: 1)
    entry = CorpusEntry.find_by!(survey_id: survey.id)
    assert entry.opted_in?
    assert entry.whole_verto_offered?, "own + every set = the whole Verto, stored as {}"
    assert_equal @admin, entry.opted_in_by
  end

  test "a common-set-only submission stores the narrowed scope" do
    survey = build_survey
    sign_in @admin

    post ask_submissions_path, params: { vertos: { survey.id => { set_ids: [ "77" ] } } }

    entry = CorpusEntry.find_by!(survey_id: survey.id)
    assert_not entry.whole_verto_offered?
    assert_equal [ 77 ], entry.offered_scope["common_question_set_ids"]
    assert_equal false, entry.offered_scope["own_questions"]
    assert entry.offers_card?(survey.cards.second)
    assert_not entry.offers_card?(survey.cards.first)
  end

  test "a set id the survey does not carry is discarded, not stored" do
    survey = build_survey
    sign_in @admin

    post ask_submissions_path, params: { vertos: { survey.id => { own: "1", set_ids: [ "9999" ] } } }

    entry = CorpusEntry.find_by!(survey_id: survey.id)
    assert_not entry.whole_verto_offered?, "own questions only — the invented set must not widen it"
    assert_equal [], entry.offered_scope["common_question_set_ids"]
  end

  test "an unpublished Verto is refused however the form was crafted" do
    survey = build_survey(published: false)
    sign_in @admin

    assert_enqueued_emails 0 do
      post ask_submissions_path, params: { vertos: { survey.id => { own: "1" } } }
    end

    assert_redirected_to ask_path(submitted: 0)
    assert_nil CorpusEntry.find_by(survey_id: survey.id)
  end

  test "a Verto below the response bar is refused" do
    survey = build_survey(responses: CorpusEntry::SUBMISSION_MIN_RESPONSES - 1)
    sign_in @admin

    post ask_submissions_path, params: { vertos: { survey.id => { own: "1" } } }

    assert_nil CorpusEntry.find_by(survey_id: survey.id)
  end

  test "another organisation's Verto is refused" do
    other_org = Organisation.create!(name: "Other", slug: "as-o-#{SecureRandom.hex(3)}")
    survey = build_survey
    survey.update!(organisation: other_org)
    sign_in @admin

    post ask_submissions_path, params: { vertos: { survey.id => { own: "1" } } }

    assert_nil CorpusEntry.find_by(survey_id: survey.id)
  end

  test "a member who is not an admin cannot submit" do
    survey = build_survey
    member = User.create!(name: "Mel Member", email_address: "as-m-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    member.verify_email!
    @org.memberships.create!(user: member, role: "member")
    sign_in member

    post ask_submissions_path, params: { vertos: { survey.id => { own: "1" } } }

    assert_response :redirect
    assert_nil CorpusEntry.find_by(survey_id: survey.id)
  end

  test "the picker CTA renders for admins and not for members" do
    build_survey
    sign_in @admin
    get ask_path
    assert_select ".ask-submit-cta"
    assert_select ".ask-modal-overlay"

    member = User.create!(name: "Mel", email_address: "as-m2-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    member.verify_email!
    @org.memberships.create!(user: member, role: "member")
    sign_in member
    get ask_path
    assert_select ".ask-submit-cta", count: 0
    assert_select ".ask-modal-overlay", count: 0
  end

  test "the redirect lands on the modal's success pane" do
    survey = build_survey
    sign_in @admin

    post ask_submissions_path, params: { vertos: { survey.id => { own: "1", set_ids: [ "77" ] } } }
    follow_redirect!

    assert_select ".ask-modal-overlay.is-open"
    assert_select ".ask-modal.is-done"
  end

  test "approving from the review queue emails the submitter their decision" do
    survey = build_survey
    sign_in @admin
    post ask_submissions_path, params: { vertos: { survey.id => { own: "1", set_ids: [ "77" ] } } }
    entry = CorpusEntry.find_by!(survey_id: survey.id)

    previous = ENV["BLAZER_STAFF_EMAILS"]
    ENV["BLAZER_STAFF_EMAILS"] = @admin.email_address
    begin
      assert_enqueued_emails 1 do
        patch corpus_review_path(entry), params: { decision: "approve" }
      end
    ensure
      previous.nil? ? ENV.delete("BLAZER_STAFF_EMAILS") : ENV["BLAZER_STAFF_EMAILS"] = previous
    end

    assert entry.reload.approved?
  end
end
