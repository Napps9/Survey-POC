require "test_helper"

class Comms::AudienceResolverTest < ActiveSupport::TestCase
  def make_user(email, verified: true, orgs: [], role: "member")
    user = User.create!(name: "U", email_address: email, password: "verylongpassword",
                        email_verified_at: verified ? Time.current : nil)
    orgs.each { |org| org.memberships.create!(user: user, role: role) }
    user
  end

  def setup
    @org_a = Organisation.create!(name: "A", slug: "ar-a-#{SecureRandom.hex(3)}")
    @org_b = Organisation.create!(name: "B", slug: "ar-b-#{SecureRandom.hex(3)}")
  end

  test "all_users reaches every verified user and nobody unverified" do
    make_user("ar-v-#{SecureRandom.hex(3)}@test.com")
    unverified = make_user("ar-u-#{SecureRandom.hex(3)}@test.com", verified: false)

    emails = Comms::AudienceResolver.resolve({ "kind" => "all_users" }).map { |r| r[:email] }
    assert_not_includes emails, unverified.email_address
    assert_operator emails.size, :>=, 1
  end

  test "organisations kind scopes to the listed orgs, with an admin filter" do
    admin  = make_user("ar-adm-#{SecureRandom.hex(3)}@test.com", orgs: [ @org_a ], role: "admin")
    member = make_user("ar-mem-#{SecureRandom.hex(3)}@test.com", orgs: [ @org_a ])
    other  = make_user("ar-oth-#{SecureRandom.hex(3)}@test.com", orgs: [ @org_b ])

    any = Comms::AudienceResolver.resolve(
      { "kind" => "organisations", "organisation_ids" => [ @org_a.id ], "role" => "any" }
    ).map { |r| r[:email] }
    assert_includes any, admin.email_address
    assert_includes any, member.email_address
    assert_not_includes any, other.email_address

    admins = Comms::AudienceResolver.resolve(
      { "kind" => "organisations", "organisation_ids" => [ @org_a.id ], "role" => "admin" }
    ).map { |r| r[:email] }
    assert_equal [ admin.email_address ], admins
  end

  test "a user in two listed orgs appears once" do
    dual = make_user("ar-dual-#{SecureRandom.hex(3)}@test.com", orgs: [ @org_a, @org_b ])

    rows = Comms::AudienceResolver.resolve(
      { "kind" => "organisations", "organisation_ids" => [ @org_a.id, @org_b.id ] }
    )
    assert_equal 1, rows.count { |r| r[:email] == dual.email_address }
  end

  test "users kind resolves by email, normalized" do
    user = make_user("ar-pick-#{SecureRandom.hex(3)}@test.com")

    rows = Comms::AudienceResolver.resolve(
      { "kind" => "users", "emails" => [ "  #{user.email_address.upcase}  " ] }
    )
    assert_equal [ user.email_address ], rows.map { |r| r[:email] }
    assert_equal user.id, rows.first[:user_id]
  end

  test "list kind resolves imported contacts" do
    list = EmailList.create!(name: "L")
    list.email_list_contacts.create!(email: "one@example.org", name: "One")
    list.email_list_contacts.create!(email: "two@example.org")

    rows = Comms::AudienceResolver.resolve({ "kind" => "list", "list_id" => list.id })
    assert_equal %w[one@example.org two@example.org], rows.map { |r| r[:email] }.sort
    assert rows.all? { |r| r[:contact_id].present? && r[:user_id].nil? }
  end

  test "suppressions are subtracted from every kind" do
    user = make_user("ar-sup-#{SecureRandom.hex(3)}@test.com")
    list = EmailList.create!(name: "L")
    list.email_list_contacts.create!(email: "gone@example.org")
    EmailSuppression.record!(user.email_address, reason: "unsubscribe")
    EmailSuppression.record!("gone@example.org", reason: "hard_bounce")

    user_rows = Comms::AudienceResolver.resolve({ "kind" => "users", "emails" => [ user.email_address ] })
    list_rows = Comms::AudienceResolver.resolve({ "kind" => "list", "list_id" => list.id })

    assert_empty user_rows
    assert_empty list_rows
  end

  test "a malformed or unknown definition resolves to empty, never everyone" do
    make_user("ar-any-#{SecureRandom.hex(3)}@test.com")

    assert_empty Comms::AudienceResolver.resolve(nil)
    assert_empty Comms::AudienceResolver.resolve("junk")
    assert_empty Comms::AudienceResolver.resolve({ "kind" => "everyone!!" })
    assert_empty Comms::AudienceResolver.resolve({ "kind" => "organisations", "organisation_ids" => [] })
    assert_empty Comms::AudienceResolver.resolve({ "kind" => "list", "list_id" => "nope" })
  end

  test "suppression record! is idempotent and keeps the first reason" do
    EmailSuppression.record!("Twice@Example.org ", reason: "unsubscribe")
    EmailSuppression.record!("twice@example.org", reason: "complaint")

    rows = EmailSuppression.where(email: "twice@example.org")
    assert_equal 1, rows.count
    assert_equal "unsubscribe", rows.first.reason
  end
end
