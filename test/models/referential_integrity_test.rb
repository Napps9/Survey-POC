require "test_helper"

# P1-9. Three belongs_to columns had no foreign key, so a delete that didn't go
# through Active Record could leave rows pointing at nothing. Every one had a
# `dependent:` on the Rails side, which is a convention, not a constraint.
#
# The interesting half is the second test: adding an FK converts silent
# orphaning into a hard failure, so the cascade that used to leave junk behind
# has to actually clean up first. That's the way this change could break
# production rather than protect it.
class ReferentialIntegrityTest < ActiveSupport::TestCase
  def setup
    @org  = Organisation.create!(name: "O", slug: "ri-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "ri-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
  end

  test "an identity cannot point at a user that isn't there" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      ActiveRecord::Base.connection.execute(
        "INSERT INTO identities (provider, uid, user_id, created_at, updated_at) " \
        "VALUES ('google', 'ri-#{SecureRandom.hex(3)}', 999999, datetime('now'), datetime('now'))"
      )
    end
  end

  test "deleting a user takes its identities with it" do
    @user.identities.create!(provider: "google", uid: "ri-#{SecureRandom.hex(4)}")
    assert_difference -> { Identity.count }, -1 do
      @user.destroy!
    end
  end

  test "a shared Common Question set can still be deleted" do
    # The regression the FK could have introduced. Organisation destroys its
    # common_question_sets, and a set can be shared with a partnership in
    # ANOTHER organisation, whose join rows the owning org's cascade never
    # touches — so without the new has_many on CommonQuestionSet this raises.
    other_org   = Organisation.create!(name: "P", slug: "ri-p-#{SecureRandom.hex(3)}")
    partnership = other_org.partnerships.create!(name: "Alliance")
    set         = @org.common_question_sets.create!(name: "S", theme: "T", key_insight: "x",
                                                    default_locale: "en")
    partnership.partnership_common_question_sets.create!(common_question_set: set)

    assert_difference -> { PartnershipCommonQuestionSet.count }, -1 do
      set.destroy!
    end
  end

  test "destroying the owning organisation of a cross-org shared set works" do
    # The same hazard one level up, and the path that actually runs in
    # production: an org being deleted while one of its sets is shared outward.
    other_org   = Organisation.create!(name: "P", slug: "ri-p2-#{SecureRandom.hex(3)}")
    partnership = other_org.partnerships.create!(name: "Alliance")
    set         = @org.common_question_sets.create!(name: "S", theme: "T", key_insight: "x",
                                                    default_locale: "en")
    partnership.partnership_common_question_sets.create!(common_question_set: set)

    assert_nothing_raised { @org.destroy! }
    assert_equal 0, PartnershipCommonQuestionSet.where(common_question_set_id: set.id).count
  end

  test "a share row cannot point at a partnership that isn't there" do
    set = @org.common_question_sets.create!(name: "S", theme: "T", key_insight: "x",
                                            default_locale: "en")
    assert_raises(ActiveRecord::InvalidForeignKey) do
      ActiveRecord::Base.connection.execute(
        "INSERT INTO partnership_common_question_sets " \
        "(partnership_id, common_question_set_id, created_at, updated_at) " \
        "VALUES (999999, #{set.id}, datetime('now'), datetime('now'))"
      )
    end
  end

  test "the regions query has an index behind it" do
    # PlayerController#regions is public and filters exactly on this pair, so
    # it's an amplification target if it ever goes to a sequential scan.
    indexes = ActiveRecord::Base.connection.indexes(:responses).map { |i| i.columns }
    assert_includes indexes, [ "survey_id", "region_country" ]
  end

  test "region_label is deliberately not in that index" do
    # #regions groups by country only — the label rides on the row but is never
    # filtered or grouped on, so indexing it would be dead weight.
    indexes = ActiveRecord::Base.connection.indexes(:responses).map { |i| i.columns }
    assert_not_includes indexes, [ "survey_id", "region_country", "region_label" ]
  end
end
