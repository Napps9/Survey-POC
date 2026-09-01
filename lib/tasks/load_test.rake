namespace :load_test do
  desc "Seed the load-test Verto + N responses (LOAD_TEST_SEED=1 RESPONSES=50000). " \
       "Additive-only; for throwaway load-test databases — see test/load/README.md."
  task seed: :environment do
    LoadTestSeeder.run!(responses: Integer(ENV.fetch("RESPONSES", "50000")))
  end
end
