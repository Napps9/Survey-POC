require "test_helper"

class FunderTest < ActiveSupport::TestCase
  def build_org(name = "Org")
    Organisation.create!(name: name, slug: "#{name.parameterize}-#{SecureRandom.hex(3)}")
  end

  test "seats_used counts active memberships and pending invites, not suspended ones" do
    creator = build_org("Creator")
    funder = creator.funders.create!(name: "Fund", seat_count: 3)

    org_a = build_org("A")
    org_b = build_org("B")
    FunderMembership.assign!(funder: funder, organisation: org_a)
    membership_b = FunderMembership.assign!(funder: funder, organisation: org_b)
    membership_b.suspend!

    invited_admin = User.create!(name: "I", email_address: "i-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    funder.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@funder.invite",
      role: "admin", kind: "licensee", organisation: creator,
      invited_by: invited_admin, expires_at: 14.days.from_now
    )

    assert_equal 2, funder.seats_used # 1 active membership + 1 pending invite
    assert_equal 1, funder.seats_available
    assert funder.seats_available?
  end

  test "seats_available is zero once seat_count is reached" do
    creator = build_org("Creator2")
    funder = creator.funders.create!(name: "Fund2", seat_count: 1)
    org_a = build_org("A2")
    FunderMembership.assign!(funder: funder, organisation: org_a)

    assert_equal 0, funder.seats_available
    refute funder.seats_available?
  end

  test "requires a unique name per creator organisation" do
    creator = build_org("Creator3")
    creator.funders.create!(name: "Dup", seat_count: 1)
    dup = creator.funders.new(name: "Dup", seat_count: 1)
    refute dup.valid?
  end
end
