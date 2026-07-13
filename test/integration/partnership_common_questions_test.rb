require "test_helper"

class PartnershipCommonQuestionsTest < ActionDispatch::IntegrationTest
  def make_user_in_org(suffix, org)
    user = User.create!(name: "U#{suffix}", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    user
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def setup
    @creator_org = Organisation.create!(name: "Creator", slug: "creator-#{SecureRandom.hex(2)}")
    @partner_org = Organisation.create!(name: "Partner", slug: "partner-#{SecureRandom.hex(2)}")
    @creator     = make_user_in_org("c", @creator_org)
    @partner     = make_user_in_org("p", @partner_org)
    @partnership    = @creator_org.partnerships.create!(name: "Pilot")
    @partnership.partnership_memberships.create!(organisation: @partner_org, status: "active")
    @set = @creator_org.common_question_sets.create!(name: "Core battery")
    @set.common_questions.create!(text: "How confident do you feel?", card_type: "range")
    @set.common_questions.create!(text: "Would you recommend us?", card_type: "yes_no")
  end

  test "creator shares a set and the partner sees its questions" do
    sign_in @creator
    post partnership_partnership_common_question_sets_path(@partnership), params: { common_question_set_id: @set.id }
    assert_redirected_to partnership_path(@partnership)
    assert_equal 1, @partnership.partnership_common_question_sets.count

    follow_redirect!
    assert_match "Core battery", response.body

    sign_in @partner
    get partnership_path(@partnership)
    assert_response :success
    assert_match "Common Questions shared with you", response.body
    assert_match "Core battery", response.body
    assert_match "How confident do you feel?", response.body
    assert_match "Would you recommend us?", response.body
  end

  test "only the partnership creator can share or remove sets" do
    acs = @partnership.partnership_common_question_sets.create!(common_question_set: @set)

    sign_in @partner
    foreign_set = @partner_org.common_question_sets.create!(name: "Partner set")
    post partnership_partnership_common_question_sets_path(@partnership), params: { common_question_set_id: foreign_set.id }
    assert_redirected_to partnership_path(@partnership)
    assert_equal 1, @partnership.partnership_common_question_sets.count, "partner must not be able to share"

    delete partnership_partnership_common_question_set_path(@partnership, acs)
    assert_equal 1, @partnership.partnership_common_question_sets.reload.count, "partner must not be able to remove"
  end

  test "removing a set hides it from partners; archived sets are hidden too" do
    acs = @partnership.partnership_common_question_sets.create!(common_question_set: @set)

    sign_in @creator
    delete partnership_partnership_common_question_set_path(@partnership, acs)
    assert_equal 0, @partnership.partnership_common_question_sets.count

    archived = @creator_org.common_question_sets.create!(name: "Old battery", deleted_at: Time.current)
    @partnership.partnership_common_question_sets.create!(common_question_set: archived)
    sign_in @partner
    get partnership_path(@partnership)
    assert_response :success
    refute_match "Old battery", response.body, "archived sets must not show to partners"
  end

  test "the section is named Partners everywhere" do
    sign_in @creator
    get partnerships_path
    assert_response :success
    assert_match "Partners", response.body
    refute_match "Collective Impact", response.body, "the old feature name is retired"
    refute_match(/[Aa]lliance/, response.body, "no raw Alliance leaks")

    get root_path
    assert_match "Partners", response.body, "nav chip should use the new name"
  end
end
