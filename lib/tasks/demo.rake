namespace :demo do
  desc "Seed (or reset) the VertoNow demo account: an org, a partner org, a Collective " \
       "Impact alliance, four fully-featured Vertos, and simulated respondents. " \
       "Safe to re-run — wipes and rebuilds only the demo org's own data. " \
       "Requires DEMO_PASSWORD (12+ characters) in the environment."
  task seed: :environment do
    DemoSeeder.new.call
  end

  desc "Remove the VertoNow demo account and everything under it (Vertos, responses, alliance)."
  task destroy: :environment do
    DemoSeeder.new.destroy!
  end
end
