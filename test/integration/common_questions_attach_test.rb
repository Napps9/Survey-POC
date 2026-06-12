require "test_helper"

class CommonQuestionsAttachTest < ActionDispatch::IntegrationTest
  def make_user(suffix, org)
    user = User.create!(name: "U#{suffix}", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    user
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # Stub SurveyGenerator so its output echoes the common_cards it was handed —
  # lets us observe exactly which questions were woven in.
  def with_echoing_generator
    fake = Object.new
    def fake.call(**kwargs)
      { "title" => "T", "description" => "d", "theme" => "T", "audience_age" => "a",
        "key_insight" => "k",
        "cards" => [ { "type" => "welcome_card", "title" => "hi" } ] + Array(kwargs[:common_cards]) }
    end
    SurveyGenerator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    SurveyGenerator.singleton_class.remove_method(:new)
  end

  def generate_with(org_user, question_ids)
    with_echoing_generator do
      post generate_survey_path, params: {
        theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0",
        common_question_ids: question_ids
      }
    end
    Survey.order(:id).last
  end

  def setup
    @owner_org   = Organisation.create!(name: "Owner", slug: "own-#{SecureRandom.hex(2)}")
    @partner_org = Organisation.create!(name: "Partner", slug: "ptr-#{SecureRandom.hex(2)}")
    @owner   = make_user("o", @owner_org)
    @partner = make_user("p", @partner_org)

    @alliance = @owner_org.alliances.create!(name: "Pilot")
    @alliance.alliance_memberships.create!(organisation: @partner_org, status: "active")

    @shared = @owner_org.common_question_sets.create!(name: "Shared core")
    @q1 = @shared.common_questions.create!(text: "Confidence?", card_type: "range")
    @q2 = @shared.common_questions.create!(text: "Recommend?", card_type: "yes_no")
    @q3 = @shared.common_questions.create!(text: "Barriers?", card_type: "open_ended")
    @alliance.alliance_common_question_sets.create!(common_question_set: @shared)

    # A set the owner did NOT share with the alliance.
    @private = @owner_org.common_question_sets.create!(name: "Private set")
    @qp = @private.common_questions.create!(text: "Secret?", card_type: "open_ended")
  end

  test "partner can attach a chosen subset of shared questions" do
    sign_in @partner
    survey = generate_with(@partner, [ @q1.id, @q3.id ])

    attached = survey.cards.filter_map { |c| c["common_question_id"] }
    assert_equal [ @q1.id, @q3.id ], attached.sort
    refute_includes attached, @q2.id, "unticked question must not be woven in"
    # snapshot keeps the set id for cross-Verto aggregation
    woven = survey.cards.find { |c| c["common_question_id"] == @q1.id }
    assert_equal @shared.id, woven["common_question_set_id"]
  end

  test "partner cannot attach questions from a set not shared with them" do
    sign_in @partner
    survey = generate_with(@partner, [ @q1.id, @qp.id ])

    attached = survey.cards.filter_map { |c| c["common_question_id"] }
    assert_includes attached, @q1.id
    refute_includes attached, @qp.id, "a set not shared with the partner must be rejected"
  end

  test "owner can still pick individual questions from their own set" do
    sign_in @owner
    survey = generate_with(@owner, [ @q2.id ])

    attached = survey.cards.filter_map { |c| c["common_question_id"] }
    assert_equal [ @q2.id ], attached
  end

  test "the wizard shows shared sets and their questions to a partner" do
    sign_in @partner
    get new_survey_path
    assert_response :success
    assert_match "Shared core", response.body
    assert_match "Confidence?", response.body
    assert_match "Shared by Owner", response.body
    refute_match "Private set", response.body, "unshared owner sets must not appear to the partner"
  end
end
