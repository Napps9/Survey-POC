namespace :showcase do
  desc "Seed the showcase Verto into the Playverto org (FORCE=1 rebuilds, RESPONSES=0 skips the simulated respondents)"
  task seed: :environment do
    ShowcaseVertoSeeder.new(
      force: ENV["FORCE"].present?,
      responses: ENV["RESPONSES"] != "0"
    ).call
  end

  desc "Remove the showcase Verto"
  task destroy: :environment do
    ShowcaseVertoSeeder.new.destroy!
  end
end
