require "test_helper"

class Comms::AutomationTriggersTest < ActiveSupport::TestCase
  def make_user(verified_at: Time.current)
    User.create!(name: "U", email_address: "at-#{SecureRandom.hex(4)}@test.com",
                 password: "verylongpassword", email_verified_at: verified_at)
  end

  def automation(trigger, created_at: 1.week.ago, params: {})
    EmailAutomation.create!(name: "A", trigger_type: trigger, params: params)
                   .tap { |a| a.update_columns(created_at: created_at) }
  end

  test "user_signed_up fires per verified user, never for pre-existing ones" do
    a = automation("user_signed_up", created_at: 1.day.ago)
    older = make_user(verified_at: 3.days.ago)
    newer = make_user(verified_at: 1.hour.ago)
    unverified = User.create!(name: "U", email_address: "at-un-#{SecureRandom.hex(3)}@test.com",
                              password: "verylongpassword")

    subjects = Comms::AutomationTriggers.subjects_for(a)
    ids = subjects.map { |s| s[:user].id }
    assert_includes ids, newer.id
    assert_not_includes ids, older.id
    assert_not_includes ids, unverified.id
    assert_equal newer.email_verified_at.to_i,
                 subjects.find { |s| s[:user].id == newer.id }[:anchor].to_i
  end

  test "user_inactive anchors on last activity + N days and re-fires on a new lapse" do
    a = automation("user_inactive", created_at: 90.days.ago, params: { "inactive_days" => 7 })
    lapsed = make_user
    Session.create!(user: lapsed, ip_address: "1.1.1.1", user_agent: "t",
                    created_at: 10.days.ago, updated_at: 10.days.ago)
    active = make_user
    Session.create!(user: active, ip_address: "1.1.1.1", user_agent: "t")

    subjects = Comms::AutomationTriggers.subjects_for(a)
    ids = subjects.map { |s| s[:user].id }
    assert_includes ids, lapsed.id
    assert_not_includes ids, active.id

    first_anchor = subjects.find { |s| s[:user].id == lapsed.id }[:anchor]

    # They come back, then lapse again — the anchor moves, so the key would
    # differ and the automation can fire again.
    Session.create!(user: lapsed, ip_address: "1.1.1.1", user_agent: "t",
                    created_at: 8.days.ago, updated_at: 8.days.ago)
    second_anchor = Comms::AutomationTriggers.subjects_for(a)
                                             .find { |s| s[:user].id == lapsed.id }[:anchor]
    assert_operator second_anchor, :>, first_anchor
  end

  test "first_verto_published fires for the org's verified members with the org anchor" do
    a = automation("first_verto_published", created_at: 1.day.ago)
    org = Organisation.create!(name: "O", slug: "at-#{SecureRandom.hex(3)}")
    member = make_user
    org.memberships.create!(user: member, role: "admin")
    Survey.create!(organisation: org, title: "V", published_at: 1.hour.ago)

    subjects = Comms::AutomationTriggers.subjects_for(a)
    row = subjects.find { |s| s[:user].id == member.id }
    assert row, "member should be a subject"
    assert_equal org.id, row[:org_id]

    # An org whose first publish predates the automation never fires.
    old_org = Organisation.create!(name: "Old", slug: "at-old-#{SecureRandom.hex(3)}")
    old_member = make_user
    old_org.memberships.create!(user: old_member, role: "admin")
    Survey.create!(organisation: old_org, title: "V", published_at: 3.days.ago)

    ids = Comms::AutomationTriggers.subjects_for(a).map { |s| s[:user].id }
    assert_not_includes ids, old_member.id
  end
end
