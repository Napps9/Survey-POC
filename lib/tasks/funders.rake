namespace :funders do
  desc "Seed (or reset) a Funder-program-owner account: an organisation with " \
       "funder_enabled, an admin user, and a Funder program with seats. " \
       "Safe to re-run — wipes and rebuilds only this org's own data. " \
       "Requires FUNDER_OWNER_PASSWORD (12+ characters) in the environment."
  task seed_owner: :environment do
    FunderOwnerSeeder.new.call
  end

  desc "Remove the seeded Funder-program-owner account and its organisation."
  task destroy_owner: :environment do
    FunderOwnerSeeder.new.destroy!
  end
end
