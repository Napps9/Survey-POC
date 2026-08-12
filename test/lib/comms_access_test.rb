require "test_helper"

# The Comms gate is membership of the Playverto organisation itself — no
# env var, deny-by-default. CommsGateTest walks the HTTP surface; this
# proves the predicate.
class CommsAccessTest < ActiveSupport::TestCase
  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @other_org = Organisation.create!(name: "Customer", slug: "cst-#{SecureRandom.hex(3)}")
  end

  def make_user(email = "ca-#{SecureRandom.hex(3)}@test.com")
    User.create!(name: "U", email_address: email, password: "verylongpassword")
  end

  test "nil user is denied" do
    assert_not CommsAccess.allowed?(nil)
  end

  test "a user with no memberships is denied" do
    assert_not CommsAccess.allowed?(make_user)
  end

  test "a member of another org only is denied" do
    user = make_user
    @other_org.memberships.create!(user: user, role: "admin")

    assert_not CommsAccess.allowed?(user)
  end

  test "a member of the Playverto org is allowed, whatever the role" do
    member = make_user
    admin  = make_user
    @playverto.memberships.create!(user: member, role: "member")
    @playverto.memberships.create!(user: admin,  role: "admin")

    assert CommsAccess.allowed?(member)
    assert CommsAccess.allowed?(admin)
  end

  test "membership of Playverto plus other orgs still allows" do
    user = make_user
    @other_org.memberships.create!(user: user, role: "member")
    @playverto.memberships.create!(user: user, role: "member")

    assert CommsAccess.allowed?(user)
  end
end
