# Seeds a Funder-program-owner account: an organisation with funder_enabled
# turned on, an admin user, and a Funder program with a starting seat count —
# the account you'd log in as to create/manage Funder programs and license
# seats to other organisations.
#
# Usage:
#   FUNDER_OWNER_PASSWORD='a-strong-passphrase' bin/rails funders:seed_owner
#   bin/rails funders:destroy_owner
#
# Re-running `funders:seed_owner` is safe — it destroys and rebuilds only the
# data under this org's own slug, so it always converges on the same known
# state (and picks up whatever password you passed this run).
class FunderOwnerSeeder
  ORG_SLUG    = "playverto-funders"
  ORG_NAME    = "Playverto Funders"
  ADMIN_EMAIL = "funder-owner@playverto.com"
  FUNDER_NAME = "Demo Funder Program"
  SEAT_COUNT  = 25

  def call
    password = require_password!

    ActiveRecord::Base.transaction do
      destroy_existing!
      org = create_organisation!
      create_user!(org, password)
      create_funder!(org)
    end

    print_summary
  end

  def destroy!
    ActiveRecord::Base.transaction { destroy_existing! }
    puts "Removed the Funder-owner account (#{ORG_SLUG})."
  end

  private

  def require_password!
    password = ENV["FUNDER_OWNER_PASSWORD"]
    if password.blank? || password.length < 12
      abort <<~MSG
        Set FUNDER_OWNER_PASSWORD (12+ characters) before running this task, e.g.:
          FUNDER_OWNER_PASSWORD='a-strong-passphrase' bin/rails funders:seed_owner
      MSG
    end
    password
  end

  def destroy_existing!
    Organisation.where(slug: ORG_SLUG).find_each(&:destroy!)
    User.where(email_address: ADMIN_EMAIL).find_each(&:destroy!)
  end

  def create_organisation!
    Organisation.create!(name: ORG_NAME, slug: ORG_SLUG, funder_enabled: true)
  end

  def create_user!(org, password)
    user = User.create!(name: "Funder Owner", email_address: ADMIN_EMAIL, password: password)
    Membership.create!(user: user, organisation: org, role: "admin")
    user
  end

  def create_funder!(org)
    Funder.create!(organisation: org, name: FUNDER_NAME, seat_count: SEAT_COUNT)
  end

  def print_summary
    puts "\nFunder-owner account ready:"
    puts "  Organisation  : #{ORG_NAME} (#{ORG_SLUG}), funder_enabled: true"
    puts "  Admin login   : #{ADMIN_EMAIL} / the password you set in FUNDER_OWNER_PASSWORD"
    puts "  Funder program: #{FUNDER_NAME} (#{SEAT_COUNT} seats)"
  end
end
