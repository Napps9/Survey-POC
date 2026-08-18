# Provisions the Alpbach client account and the Playverto people who work in it.
#
# Alpbach is a MANAGED account: the Playverto team builds its Verto, so the org
# is created with verto_creation_enabled false. Jamie builds it and Nick (the
# owner) works in it too, so both are admins of Alpbach — but it is their
# membership of the PLAYVERTO org, not their Alpbach role, that actually lets
# them create inside a restricted account (see PlayvertoStaff).
#
# Called from the data migrations under db/migrate rather than only from
# db/seeds.rb because Render's pre-deploy `db:prepare` migrates an existing
# database but never re-seeds it — the same reason GrantCommsAccessToOwner is a
# migration. Lives here rather than inline in a migration so it can be tested,
# and so a later change (adding a person) is one edit plus a migration that
# re-runs it, not a rewrite.
#
# EVERY write is create-only, which is what makes it safe to re-run:
#   * an existing user keeps their password and name (Jamie already has an
#     account — this must never reset it);
#   * the flag is set in the find_or_create_by! block, so re-running cannot
#     re-disable creation for an account someone has deliberately enabled;
#   * an existing membership keeps whatever role it has.
class AlpbachAccountProvisioner
  ORG_SLUG    = "alpbach"
  ORG_NAME    = "Alpbach"
  JAMIE_EMAIL = "jamie@playverto.com"
  JAMIE_NAME  = "Jamie"
  NICK_EMAIL  = "nick@playverto.com"
  NICK_NAME   = "Nick"

  def call
    alpbach   = find_or_create_alpbach!
    playverto = find_or_create_playverto!

    jamie = find_or_create_user!(JAMIE_EMAIL, JAMIE_NAME)
    nick  = find_or_create_user!(NICK_EMAIL, NICK_NAME)

    # Admin in Alpbach is "full features in the Alpbach account".
    Membership.find_or_create_by!(user: jamie, organisation: alpbach) { |m| m.role = "admin" }
    Membership.find_or_create_by!(user: nick,  organisation: alpbach) { |m| m.role = "admin" }

    # Member — not admin — of Playverto for Jamie: the membership itself is the
    # staff capability, and he has no need to administer Playverto's own org.
    # Nick's Playverto membership is created by db/seeds.rb and by
    # GrantCommsAccessToOwner as an ADMIN, and find_or_create_by! leaves it
    # alone — this line only matters on a database where neither has run.
    Membership.find_or_create_by!(user: jamie, organisation: playverto) { |m| m.role = "member" }
    Membership.find_or_create_by!(user: nick,  organisation: playverto) { |m| m.role = "admin" }

    [ alpbach, jamie, nick ]
  end

  private

  def find_or_create_alpbach!
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
  # the partner/funder accounts use. Both of these people already have accounts,
  # so in practice the create branch is the safety net, not the path — and
  # because it only runs on create, an existing password is never touched.
  def find_or_create_user!(email, name)
    User.find_or_create_by!(email_address: email) do |u|
      u.name             = name
      u.password         = SecureRandom.hex(32)
      u.password_pending = true
    end
  end
end
