# Provisions the Alpbach client account and Jamie's access to it.
#
# Alpbach is a MANAGED account: the Playverto team builds its Verto, so the org
# is created with verto_creation_enabled false. Jamie builds it, so he is an
# admin of Alpbach and a member of the Playverto org — and it is that Playverto
# membership, not his Alpbach role, that lets him create inside a restricted
# account (see PlayvertoStaff).
#
# Called from db/migrate/20260818120001_provision_alpbach_account.rb rather than
# db/seeds.rb because Render's pre-deploy `db:prepare` migrates an existing
# database but never re-seeds it — the same reason GrantCommsAccessToOwner is a
# migration. Lives here rather than inline in the migration so it can be tested.
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

  def call
    alpbach   = find_or_create_alpbach!
    playverto = find_or_create_playverto!
    jamie     = find_or_create_jamie!

    # Admin in Alpbach is "full features in the Alpbach account".
    Membership.find_or_create_by!(user: jamie, organisation: alpbach) { |m| m.role = "admin" }
    # Member — not admin — of Playverto: the membership itself is the staff
    # capability, and Jamie has no need to administer Playverto's own org.
    Membership.find_or_create_by!(user: jamie, organisation: playverto) { |m| m.role = "member" }

    [ alpbach, jamie ]
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
  # the partner/funder accounts use. Jamie already exists, so in practice this
  # branch is the safety net, not the path.
  def find_or_create_jamie!
    User.find_or_create_by!(email_address: JAMIE_EMAIL) do |u|
      u.name             = JAMIE_NAME
      u.password         = SecureRandom.hex(32)
      u.password_pending = true
    end
  end
end
