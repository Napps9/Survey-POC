require "test_helper"

class FunderOwnerSeederTest < ActiveSupport::TestCase
  setup { FunderOwnerSeeder.new.destroy! }
  teardown { FunderOwnerSeeder.new.destroy! }

  test "creates an admin user, a funder_enabled org, and an owned Funder program" do
    ENV["FUNDER_OWNER_PASSWORD"] = "a-strong-passphrase"
    FunderOwnerSeeder.new.call

    org = Organisation.find_by!(slug: FunderOwnerSeeder::ORG_SLUG)
    assert org.funder_enabled?

    user = User.find_by!(email_address: FunderOwnerSeeder::ADMIN_EMAIL)
    assert user.authenticate("a-strong-passphrase")
    assert_equal "admin", user.memberships.find_by!(organisation: org).role

    funder = org.funders.find_by!(name: FunderOwnerSeeder::FUNDER_NAME)
    assert_equal FunderOwnerSeeder::SEAT_COUNT, funder.seat_count
  ensure
    ENV.delete("FUNDER_OWNER_PASSWORD")
  end

  test "re-running converges instead of raising a uniqueness error" do
    ENV["FUNDER_OWNER_PASSWORD"] = "a-strong-passphrase"
    FunderOwnerSeeder.new.call
    assert_nothing_raised { FunderOwnerSeeder.new.call }
  ensure
    ENV.delete("FUNDER_OWNER_PASSWORD")
  end

  test "aborts without a sufficiently long FUNDER_OWNER_PASSWORD" do
    ENV.delete("FUNDER_OWNER_PASSWORD")
    assert_raises(SystemExit) { FunderOwnerSeeder.new.call }
  end
end
