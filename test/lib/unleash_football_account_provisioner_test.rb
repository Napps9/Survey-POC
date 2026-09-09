require "test_helper"

# The Unleash Football client account is provisioned from two disjoint places
# (the data migration for an existing database, db/seeds.rb for a fresh one),
# so the properties that matter are all about running MORE THAN ONCE without
# doing damage — most sharply, never resetting the password of a user who
# already has an account, which both of these people do.
class UnleashFootballAccountProvisionerTest < ActiveSupport::TestCase
  def setup
    destroy_unleash_football!
  end

  def teardown
    destroy_unleash_football!
  end

  def destroy_unleash_football!
    Organisation.where(slug: UnleashFootballAccountProvisioner::ORG_SLUG).find_each(&:destroy!)
    User.where(email_address: [ UnleashFootballAccountProvisioner::JAMIE_EMAIL,
                                UnleashFootballAccountProvisioner::NICK_EMAIL ]).find_each(&:destroy!)
  end

  def unleash_football = Organisation.find_by(slug: UnleashFootballAccountProvisioner::ORG_SLUG)
  def playverto        = Organisation.find_by(slug: PlayvertoStaff::SLUG)
  def jamie            = User.find_by(email_address: UnleashFootballAccountProvisioner::JAMIE_EMAIL)
  def nick             = User.find_by(email_address: UnleashFootballAccountProvisioner::NICK_EMAIL)

  test "creates a managed Unleash Football org" do
    UnleashFootballAccountProvisioner.new.call

    assert unleash_football, "expected the Unleash Football organisation"
    assert_equal "Unleash Football", unleash_football.name
    refute unleash_football.verto_creation_enabled?,
           "Unleash Football is a managed account — its whole point is that it cannot create Vertos"
  end

  test "puts Jamie in Unleash Football as an admin and in Playverto as a member" do
    UnleashFootballAccountProvisioner.new.call

    assert jamie, "expected Jamie's user"
    assert_equal "admin",  jamie.memberships.find_by(organisation: unleash_football).role
    assert_equal "member", jamie.memberships.find_by(organisation: playverto).role

    # The Playverto membership is what actually lets him create inside the account.
    assert PlayvertoStaff.member?(jamie)
  end

  test "puts Nick in Unleash Football as an admin, with his Playverto admin role" do
    UnleashFootballAccountProvisioner.new.call

    assert nick, "expected Nick's user"
    assert_equal "admin", nick.memberships.find_by(organisation: unleash_football).role
    assert_equal "admin", nick.memberships.find_by(organisation: playverto).role
    assert PlayvertoStaff.member?(nick)
  end

  # Both of them are Playverto staff, so neither is bound by the account's own
  # restriction — that is the whole reason they can work in it. This provisioner
  # grants those memberships itself rather than leaning on the Alpbach one
  # having run, so the property holds on a database where it is the only thing
  # that has.
  test "both grantees can create inside the managed account" do
    UnleashFootballAccountProvisioner.new.call

    [ jamie, nick ].each do |user|
      assert PlayvertoStaff.member?(user),
             "#{user.email_address} should be able to create in Unleash Football"
    end
  end

  test "running twice changes nothing" do
    UnleashFootballAccountProvisioner.new.call

    assert_no_difference [ "Organisation.count", "User.count", "Membership.count" ] do
      assert_nothing_raised { UnleashFootballAccountProvisioner.new.call }
    end
  end

  # Both of these people already have accounts — Alpbach provisioned them. A
  # provisioner that reset a password on every deploy would lock them out
  # silently, and the deploy would still be green.
  test "an existing user keeps their password, name and claimed status" do
    [ UnleashFootballAccountProvisioner::JAMIE_EMAIL,
      UnleashFootballAccountProvisioner::NICK_EMAIL ].each do |email|
      User.where(email_address: email).find_each(&:destroy!)
      User.create!(name: "Already #{email}", email_address: email, password: "verylongpassword")
    end

    UnleashFootballAccountProvisioner.new.call

    [ UnleashFootballAccountProvisioner::JAMIE_EMAIL,
      UnleashFootballAccountProvisioner::NICK_EMAIL ].each do |email|
      user = User.find_by(email_address: email)
      assert user.authenticate("verylongpassword"), "#{email}: password was reset by provisioning"
      assert_equal "Already #{email}", user.name, "#{email}: name was overwritten by provisioning"
      refute user.password_pending?, "#{email}: a claimed account was marked password-pending again"
    end
  end

  # If someone deliberately turns creation on for the account, the next deploy
  # must not quietly turn it back off.
  test "does not re-disable creation for an org an operator has enabled" do
    UnleashFootballAccountProvisioner.new.call
    unleash_football.update!(verto_creation_enabled: true)

    UnleashFootballAccountProvisioner.new.call

    assert unleash_football.reload.verto_creation_enabled?,
           "a re-run fought the operator's decision instead of leaving it alone"
  end

  # An existing membership must keep whatever role it has been given since.
  test "does not change an existing membership's role" do
    UnleashFootballAccountProvisioner.new.call
    jamie.memberships.find_by(organisation: playverto).update!(role: "admin")
    nick.memberships.find_by(organisation: unleash_football).update!(role: "member")

    UnleashFootballAccountProvisioner.new.call

    assert_equal "admin",  jamie.memberships.find_by(organisation: playverto).role
    assert_equal "member", nick.memberships.find_by(organisation: unleash_football).role
  end

  # The Alpbach account and this one share both of their people. Provisioning
  # one must not disturb the other's memberships — they are separate accounts
  # that happen to be staffed by the same two admins.
  test "leaves the Alpbach account and its memberships alone" do
    AlpbachAccountProvisioner.new.call
    alpbach = Organisation.find_by(slug: AlpbachAccountProvisioner::ORG_SLUG)

    UnleashFootballAccountProvisioner.new.call

    assert_equal "admin", jamie.memberships.find_by(organisation: alpbach).role
    assert_equal "admin", nick.memberships.find_by(organisation: alpbach).role
    refute_equal alpbach.id, unleash_football.id
  end
end
