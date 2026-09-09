# Provisions the Unleash Football client account and the Playverto people who
# work in it.
#
# Same shape as AlpbachAccountProvisioner, and for the same reasons: Unleash
# Football is a MANAGED account, so the org is created with
# verto_creation_enabled false and the Playverto team builds its Verto. Jamie
# and Nick are both admins of it — but it is their membership of the PLAYVERTO
# org, not their Unleash Football role, that actually lets them create inside a
# restricted account (see PlayvertoStaff). Those Playverto memberships are
# granted here rather than assumed: this class is what makes "both grantees can
# build in the managed account" true, so it must not depend on another
# provisioner having run first.
#
# Called from db/migrate as well as db/seeds.rb because the two paths are
# disjoint — Render's pre-deploy `db:prepare` migrates an existing database and
# never re-seeds, while a fresh database loads the schema (marking every
# migration as already run) and then seeds. Whichever fires, the other is a
# no-op.
#
# EVERY write is create-only, which is what makes it safe to re-run:
#   * an existing user keeps their password and name (both of these people
#     already have accounts — this must never reset one);
#   * the managed flag is set in the find_or_create_by! block, so re-running
#     cannot re-disable creation for an account someone has deliberately
#     enabled;
#   * an existing membership keeps whatever role it has.
class UnleashFootballAccountProvisioner
  ORG_SLUG    = "unleash-football"
  ORG_NAME    = "Unleash Football"
  JAMIE_EMAIL = "jamie@playverto.com"
  JAMIE_NAME  = "Jamie"
  NICK_EMAIL  = "nick@playverto.com"
  NICK_NAME   = "Nick"

  def call
    unleash_football = find_or_create_unleash_football!
    playverto        = find_or_create_playverto!

    jamie = find_or_create_user!(JAMIE_EMAIL, JAMIE_NAME)
    nick  = find_or_create_user!(NICK_EMAIL, NICK_NAME)

    # Admin in Unleash Football is "full features in the Unleash Football
    # account" — members, invites, brand, sharing.
    Membership.find_or_create_by!(user: jamie, organisation: unleash_football) { |m| m.role = "admin" }
    Membership.find_or_create_by!(user: nick,  organisation: unleash_football) { |m| m.role = "admin" }

    # Member — not admin — of Playverto for Jamie: the membership itself is the
    # staff capability, and he has no need to administer Playverto's own org.
    # Nick's Playverto membership is created as an ADMIN by db/seeds.rb and by
    # GrantCommsAccessToOwner, and find_or_create_by! leaves it alone — these
    # two lines only matter on a database where none of those has run.
    Membership.find_or_create_by!(user: jamie, organisation: playverto) { |m| m.role = "member" }
    Membership.find_or_create_by!(user: nick,  organisation: playverto) { |m| m.role = "admin" }

    [ unleash_football, jamie, nick ]
  end

  private

  def find_or_create_unleash_football!
    Organisation.find_or_create_by!(slug: ORG_SLUG) do |o|
      o.name                   = ORG_NAME
      o.verto_creation_enabled = false
    end
  end

  def find_or_create_playverto!
    Organisation.find_or_create_by!(slug: PlayvertoStaff::SLUG) { |o| o.name = "Playverto" }
  end

  # Credential-free: a user we have to create gets a throwaway password and
  # claims the account through the ordinary password-reset flow, the same idiom
  # the partner/funder accounts use. Both of these people already have
  # accounts, so in practice the create branch is the safety net, not the path
  # — and because it only runs on create, an existing password is never touched.
  def find_or_create_user!(email, name)
    User.find_or_create_by!(email_address: email) do |u|
      u.name             = name
      u.password         = SecureRandom.hex(32)
      u.password_pending = true
    end
  end
end
