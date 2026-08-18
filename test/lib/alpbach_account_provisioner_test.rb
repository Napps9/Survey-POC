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
    User.where(email_address: [ AlpbachAccountProvisioner::JAMIE_EMAIL,
                                AlpbachAccountProvisioner::NICK_EMAIL ]).find_each(&:destroy!)
  end

  def alpbach   = Organisation.find_by(slug: AlpbachAccountProvisioner::ORG_SLUG)
  def playverto = Organisation.find_by(slug: PlayvertoStaff::SLUG)
  def jamie     = User.find_by(email_address: AlpbachAccountProvisioner::JAMIE_EMAIL)
  def nick      = User.find_by(email_address: AlpbachAccountProvisioner::NICK_EMAIL)

  test "creates a managed Alpbach org" do
    AlpbachAccountProvisioner.new.call

    assert alpbach, "expected the Alpbach organisation"
    assert_equal "Alpbach", alpbach.name
    refute alpbach.verto_creation_enabled?,
           "Alpbach is a managed account — its whole point is that it cannot create Vertos"
  end

  test "puts Jamie in Alpbach as an admin and in Playverto as a member" do
    AlpbachAccountProvisioner.new.call

    assert jamie, "expected Jamie's user"
    assert_equal "admin",  jamie.memberships.find_by(organisation: alpbach).role
    assert_equal "member", jamie.memberships.find_by(organisation: playverto).role

    # The Playverto membership is what actually lets him create inside Alpbach.
    assert PlayvertoStaff.member?(jamie)
  end

  test "puts Nick in Alpbach as an admin, keeping his Playverto admin role" do
    AlpbachAccountProvisioner.new.call

    assert nick, "expected Nick's user"
    assert_equal "admin", nick.memberships.find_by(organisation: alpbach).role
    assert_equal "admin", nick.memberships.find_by(organisation: playverto).role
    assert PlayvertoStaff.member?(nick)
  end

  # Both of them are Playverto staff, so neither is bound by Alpbach's own
  # restriction — that is the whole reason they can work in the account.
  test "both grantees can create inside the managed account" do
    AlpbachAccountProvisioner.new.call

    [ jamie, nick ].each do |user|
      assert PlayvertoStaff.member?(user), "#{user.email_address} should be able to create in Alpbach"
    end
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
    [ AlpbachAccountProvisioner::JAMIE_EMAIL, AlpbachAccountProvisioner::NICK_EMAIL ].each do |email|
      User.where(email_address: email).find_each(&:destroy!)
      User.create!(name: "Already #{email}", email_address: email, password: "verylongpassword")
    end

    AlpbachAccountProvisioner.new.call

    [ AlpbachAccountProvisioner::JAMIE_EMAIL, AlpbachAccountProvisioner::NICK_EMAIL ].each do |email|
      user = User.find_by(email_address: email)
      assert user.authenticate("verylongpassword"), "#{email}: password was reset by provisioning"
      assert_equal "Already #{email}", user.name, "#{email}: name was overwritten by provisioning"
      refute user.password_pending?, "#{email}: a claimed account was marked password-pending again"
    end
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
  test "does not change an existing membership's role" do
    AlpbachAccountProvisioner.new.call
    jamie.memberships.find_by(organisation: playverto).update!(role: "admin")
    nick.memberships.find_by(organisation: alpbach).update!(role: "member")

    AlpbachAccountProvisioner.new.call

    assert_equal "admin",  jamie.memberships.find_by(organisation: playverto).role
    assert_equal "member", nick.memberships.find_by(organisation: alpbach).role
  end
end
