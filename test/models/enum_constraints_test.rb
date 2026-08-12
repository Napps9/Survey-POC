require "test_helper"

# P2-8. Every constrained column already had a Rails enum or an inclusion
# validation, which holds only for writes that go through Active Record. The
# failure mode when something else writes is silent rather than loud: an
# unknown `status` simply never matches a scope, so rows drop out of counts and
# dashboards without anything erroring.
#
# These tests go around Active Record on purpose — a validation test would pass
# with or without the constraint, and prove nothing about the database.
class EnumConstraintsTest < ActiveSupport::TestCase
  def setup
    @org    = Organisation.create!(name: "O", slug: "ec-#{SecureRandom.hex(3)}")
    @user   = User.create!(name: "U", email_address: "ec-#{SecureRandom.hex(3)}@test.com",
                           password: "verylongpassword")
    @survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [])
  end

  # Inside a savepoint (requires_new), because on Postgres a statement that
  # violates a CHECK poisons the test-wrapping transaction — every later
  # statement in the test would fail with InFailedSqlTransaction. SQLite
  # carries on regardless; the savepoint makes both engines behave alike.
  def raw_update(table, id, column, value)
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute(
        "UPDATE #{table} SET #{column} = '#{value}' WHERE id = #{id}"
      )
    end
  end

  test "a leaderboard retake policy outside the enum is rejected by the database" do
    assert_raises(ActiveRecord::StatementInvalid) do
      raw_update("surveys", @survey.id, "leaderboard_retake_policy", "honour_system")
    end
    assert_equal "accumulate", @survey.reload.leaderboard_retake_policy

    Survey::LEADERBOARD_RETAKE_POLICIES.each do |policy|
      assert_nothing_raised { raw_update("surveys", @survey.id, "leaderboard_retake_policy", policy) }
    end
  end

  test "a response status outside the allowed set is rejected by the database" do
    resp = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed")

    assert_raises(ActiveRecord::StatementInvalid) do
      raw_update("responses", resp.id, "status", "archived")
    end
    assert_equal "completed", resp.reload.status
  end

  test "the allowed response statuses still write" do
    resp = @survey.responses.create!(session_token: SecureRandom.uuid, status: "started")
    Response::STATUSES.each do |status|
      assert_nothing_raised { raw_update("responses", resp.id, "status", status) }
    end
  end

  test "a membership role outside the enum is rejected by the database" do
    membership = @org.memberships.create!(user: @user, role: "admin")

    assert_raises(ActiveRecord::StatementInvalid) do
      raw_update("memberships", membership.id, "role", "owner")
    end
    assert_equal "admin", membership.reload.role
  end

  test "a partnership status outside the enum is rejected by the database" do
    partnership = @org.partnerships.create!(name: "Alliance")

    assert_raises(ActiveRecord::StatementInvalid) do
      raw_update("partnerships", partnership.id, "status", "cancelled")
    end
  end

  test "an invite kind outside the enum is rejected by the database" do
    invite = @org.invites.create!(email_address: "x-#{SecureRandom.hex(3)}@test.com",
                                  kind: "member", invited_by: @user, expires_at: 7.days.from_now)

    assert_raises(ActiveRecord::StatementInvalid) do
      raw_update("invites", invite.id, "kind", "superuser")
    end
  end

  test "Response now declares its statuses, like every other status column did" do
    # The gap this closed: without a model validation, a bad value would have
    # surfaced as a raw database exception instead of an ordinary validation
    # error the app can render.
    resp = @survey.responses.build(session_token: SecureRandom.uuid, status: "archived")
    assert_not resp.valid?
    assert_includes resp.errors[:status].join, "included"
  end

  test "every constrained column is covered by a model enum or validation" do
    # The database and the model must not drift: a value allowed by one and not
    # the other is a bug in whichever direction it goes.
    {
      Funder => :status, FunderMembership => :status, Invite => :kind,
      Membership => :role, Partnership => :status, PartnershipMembership => :status,
      FlowGeneration => :status, ReportRender => :status, VertoBuild => :status,
      Response => :status, Survey => :leaderboard_retake_policy
    }.each do |model, column|
      declared = model.respond_to?(:defined_enums) && model.defined_enums.key?(column.to_s)
      validated = model.validators_on(column).any? { |v| v.is_a?(ActiveModel::Validations::InclusionValidator) }
      assert declared || validated,
             "#{model}.#{column} has a database CHECK but nothing declaring its values in the model"
    end
  end

  test "the constraints are actually present in the schema" do
    names = ActiveRecord::Base.connection.check_constraints(:responses).map(&:name)
    assert_includes names, "chk_responses_status"

    survey_names = ActiveRecord::Base.connection.check_constraints(:surveys).map(&:name)
    assert_includes survey_names, "chk_surveys_leaderboard_retake_policy"
  end
end
