require "test_helper"

# The Alpbach client account is provisioned from two disjoint places (the data
# migration for an existing database, db/seeds.rb for a fresh one), so the
# properties that matter are all about running MORE THAN ONCE without doing
# damage — most sharply, never resetting the password of a user who already has
# an account, which Jamie does.
class AlpbachAccountProvisionerTest < ActiveSupport::TestCase
  def setup
    destroy_alpbach!
  end

  def teardown
    destroy_alpbach!
  end

  def destroy_alpbach!
    Organisation.where(slug: AlpbachAccountProvisioner::ORG_SLUG).find_each(&:destroy!)
    User.where(email_address: AlpbachAccountProvisioner::JAMIE_EMAIL).find_each(&:destroy!)
  end

  def alpbach = Organisation.find_by(slug: AlpbachAccountProvisioner::ORG_SLUG)
  def jamie   = User.find_by(email_address: AlpbachAccountProvisioner::JAMIE_EMAIL)

  test "creates a managed Alpbach org with Jamie admin there and a member of Playverto" do
    AlpbachAccountProvisioner.new.call

    assert alpbach, "expected the Alpbach organisation"
    assert_equal "Alpbach", alpbach.name
    refute alpbach.verto_creation_enabled?,
           "Alpbach is a managed account — its whole point is that it cannot create Vertos"

    assert jamie, "expected Jamie's user"
    assert_equal "admin", jamie.memberships.find_by(organisation: alpbach).role
    playverto = Organisation.find_by(slug: PlayvertoStaff::SLUG)
    assert_equal "member", jamie.memberships.find_by(organisation: playverto).role

    # The membership is what actually lets him create inside Alpbach.
    assert PlayvertoStaff.member?(jamie)
  end

  test "running twice changes nothing" do
    AlpbachAccountProvisioner.new.call

    assert_no_difference [ "Organisation.count", "User.count", "Membership.count" ] do
      assert_nothing_raised { AlpbachAccountProvisioner.new.call }
    end
  end

  # Jamie already has an account. A provisioner that reset his password on every
  # deploy would lock him out silently, and the deploy would still be green.
  test "an existing user keeps their password, name and claimed status" do
    existing = User.create!(name: "Jamie Existing",
                            email_address: AlpbachAccountProvisioner::JAMIE_EMAIL,
                            password: "verylongpassword")

    AlpbachAccountProvisioner.new.call

    existing.reload
    assert existing.authenticate("verylongpassword"), "password was reset by provisioning"
    assert_equal "Jamie Existing", existing.name, "name was overwritten by provisioning"
    refute existing.password_pending?, "a claimed account was marked password-pending again"
  end

  # If someone deliberately turns creation on for Alpbach, the next deploy must
  # not quietly turn it back off.
  test "does not re-disable creation for an org an operator has enabled" do
    AlpbachAccountProvisioner.new.call
    alpbach.update!(verto_creation_enabled: true)

    AlpbachAccountProvisioner.new.call

    assert alpbach.reload.verto_creation_enabled?,
           "a re-run fought the operator's decision instead of leaving it alone"
  end

  # An existing membership must keep whatever role it has been given since.
  test "does not downgrade an existing membership" do
    AlpbachAccountProvisioner.new.call
    playverto = Organisation.find_by(slug: PlayvertoStaff::SLUG)
    jamie.memberships.find_by(organisation: playverto).update!(role: "admin")

    AlpbachAccountProvisioner.new.call

    assert_equal "admin", jamie.memberships.find_by(organisation: playverto).role
  end
end
