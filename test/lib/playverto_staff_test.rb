require "test_helper"

# "Playverto staff" is membership of the Playverto organisation itself — the
# predicate CommsAccess was built on, extracted because the Verto-creation gate
# needs the same answer. Deny-by-default.
class PlayvertoStaffTest < ActiveSupport::TestCase
  def setup
    @playverto = Organisation.find_or_create_by!(slug: PlayvertoStaff::SLUG) { |o| o.name = "Playverto" }
    @other_org = Organisation.create!(name: "Customer", slug: "ps-#{SecureRandom.hex(3)}")
  end

  def make_user
    User.create!(name: "U", email_address: "ps-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
  end

  test "nil user is denied" do
    assert_not PlayvertoStaff.member?(nil)
  end

  test "a user with no memberships is denied" do
    assert_not PlayvertoStaff.member?(make_user)
  end

  test "membership of another org only is denied" do
    user = make_user
    @other_org.memberships.create!(user: user, role: "admin")

    assert_not PlayvertoStaff.member?(user)
  end

  # Role-blind on purpose: being inside the Playverto org is the capability.
  test "a Playverto member is staff at either role" do
    %w[member admin].each do |role|
      user = make_user
      @playverto.memberships.create!(user: user, role: role)

      assert PlayvertoStaff.member?(user), "a Playverto #{role} should be staff"
    end
  end

  test "staff who also belong to a customer org are still staff" do
    user = make_user
    @playverto.memberships.create!(user: user, role: "member")
    @other_org.memberships.create!(user: user, role: "admin")

    assert PlayvertoStaff.member?(user)
  end

  # The refactor must not have changed what Comms lets through.
  test "CommsAccess still answers exactly this predicate" do
    staff  = make_user
    @playverto.memberships.create!(user: staff, role: "member")
    outsider = make_user

    assert_equal PlayvertoStaff.member?(staff),    CommsAccess.allowed?(staff)
    assert_equal PlayvertoStaff.member?(outsider), CommsAccess.allowed?(outsider)
    assert_equal PlayvertoStaff::SLUG, CommsAccess::PLAYVERTO_SLUG
  end
end
