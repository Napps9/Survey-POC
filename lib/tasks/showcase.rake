namespace :showcase do
  desc "Seed the showcase Verto into the Playverto org in Test Mode " \
       "(FORCE=1 rebuilds, PUBLISH=1 also mints a /play link, RESPONSES=1 adds simulated respondents)"
  task seed: :environment do
    ShowcaseVertoSeeder.new(
      force: ENV["FORCE"].present?,
      publish: ENV["PUBLISH"].present?,
      # Simulated respondents lock the deck (answers are keyed by card index),
      # so they are opt-in — the opposite of what Test Mode is for.
      responses: ENV["RESPONSES"].present?
    ).call
  end

  desc "Put the existing showcase Verto into Test Mode — mint its test link, take it off /play"
  task test_mode: :environment do
    ShowcaseVertoSeeder.new.ensure_test_mode!
  end

  desc "Remove the showcase Verto"
  task destroy: :environment do
    ShowcaseVertoSeeder.new.destroy!
  end
end
