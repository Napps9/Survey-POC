# Starter Blazer queries for VertoNow staff — a first cut at "seeing usage and
# collected data" across all organisations, with VertoNow's own (internal) test
# orgs filtered out.
#
# Definitions and upsert logic live in app/lib/blazer_starter_queries.rb so this
# seed and the data migration that ships query changes share one source. This
# only creates what's missing, preserving any edits the team makes in Blazer.
created = BlazerStarterQueries.create_missing!
puts "Blazer starter queries: #{created} created."
