# Seeds a scratch database for the k6 load-test harness (test/load/).
#
# Two jobs, both additive-only:
#   1. Find-or-create a published, tokenised, leaderboard-enabled Verto under
#      its own dedicated organisation — never touching anything it didn't
#      create itself.
#   2. Bulk-insert N completed responses against it via insert_all!, the same
#      callback-free batch path VertoCsvImporter uses, because the O(N)
#      respondent endpoints (/results, /regions, /scores, /leaderboard) are
#      invisible on an empty table — a load test against 100 rows proves
#      nothing.
#
# It NEVER deletes or updates existing rows (unlike DemoSeeder, which starts
# by destroying its fixed slugs — that class must never run near production;
# this one is safe by construction but still guarded). Re-running appends more
# responses to the same Verto and prints the same play URL.
#
# Guard: refuses to run unless LOAD_TEST_SEED=1, so it can't be triggered by
# a stray rake invocation. It is intended for the throwaway load-test
# environment only — see test/load/README.md.
class LoadTestSeeder
  ORG_NAME     = "Load Test Org"
  ORG_SLUG     = "load-test-org"
  SURVEY_TITLE = "Load Test Verto"

  TOKEN_TYPES = [
    { "id" => "points", "name" => "Points", "icon" => "⭐" }
  ].freeze

  # Deck shape mirrors what test/load/journey.js answers — card indexes are
  # the contract between the two files. Change one, change the other.
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome to the load test" },
    { "type" => "multiple_choice", "text" => "How did you hear about this?",
      "options" => [ "Email", "Social", "Friend", "Other" ],
      "tokens" => { "Email" => { "points" => 2 }, "Social" => { "points" => 3 },
                    "Friend" => { "points" => 4 }, "Other" => { "points" => 1 } } },
    { "type" => "rating", "text" => "How excited are you?", "token_award" => { "points" => 2 } },
    { "type" => "multiple_choice", "text" => "Pick a colour",
      "options" => [ "Red", "Green", "Blue" ] },
    { "type" => "open_ended", "text" => "Tell us one thing you'd change." },
    { "type" => "rating", "text" => "Rate the experience overall" }
  ].freeze

  REGIONS = [ "GB", "FR", "DE", "ES", "IE", nil ].freeze

  class << self
    def run!(responses:, batch_size: 1_000, io: $stdout)
      unless ENV["LOAD_TEST_SEED"] == "1"
        raise "LoadTestSeeder refuses to run without LOAD_TEST_SEED=1 — it is " \
              "for throwaway load-test databases only (see test/load/README.md)."
      end

      # The flag says "I meant to run the seeder"; this check says "and this is
      # actually a scratch database". A mispasted DATABASE_URL pointing at
      # production nearly slipped through once — an env var can lie about what
      # it is, but a database holding real organisations cannot.
      foreign = Organisation.where.not(slug: ORG_SLUG)
      if foreign.exists?
        raise "LoadTestSeeder refuses: this database already holds " \
              "#{foreign.count} organisation(s) that are not the load-test org " \
              "(e.g. #{foreign.first.slug.inspect}). It only ever runs against " \
              "a scratch database — check DATABASE_URL."
      end

      survey   = find_or_create_survey!
      inserted = insert_responses!(survey, count: responses, batch_size: batch_size, io: io)

      io.puts "Verto:       #{survey.title} (id #{survey.id})"
      io.puts "Play path:   /play/#{survey.publish_token}"
      io.puts "Responses:   +#{inserted} this run, #{survey.responses.count} total"
      { survey: survey, inserted: inserted }
    end

    def find_or_create_survey!
      org = Organisation.find_by(slug: ORG_SLUG) ||
            Organisation.create!(name: ORG_NAME, slug: ORG_SLUG)

      org.surveys.find_by(title: SURVEY_TITLE) || org.surveys.create!(
        title: SURVEY_TITLE, theme: "Load testing", audience_age: "all",
        key_insight: "throughput", default_locale: "en", locales: [ "en" ],
        cards: CARDS.map(&:dup), token_types: TOKEN_TYPES.map(&:dup),
        tokenisation_enabled: true, leaderboard_enabled: true,
        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
      )
    end

    def insert_responses!(survey, count:, batch_size: 1_000, io: $stdout)
      cards    = survey.cards
      type_ids = survey.token_type_ids
      # Continue numbering across runs so session tokens stay globally unique.
      start = survey.responses.where("session_token LIKE 'lt-%'").count
      now   = Time.current
      total = 0

      (0...count).each_slice(batch_size) do |slice|
        rows = slice.map do |offset|
          i       = start + offset
          answers = answers_for(i)
          {
            survey_id: survey.id,
            session_token: "lt-#{i}-#{SecureRandom.hex(6)}",
            answers: answers,
            answered: true,
            status: "completed",
            token_totals: TokenGrading.totals(cards, answers, type_ids),
            player_key_digest: survey.player_key_digest("lt-player-#{i}"),
            region_country: REGIONS[i % REGIONS.length],
            demographic_birth_year: 1960 + (i % 50),
            locale: "en",
            started_at: now - 3600 + (i % 3000),
            completed_at: now - 3300 + (i % 3000),
            created_at: now, updated_at: now
          }
        end
        Response.insert_all!(rows)
        total += rows.length
        io.puts "  inserted #{total}/#{count}" if (total % 10_000).zero?
      end
      total
    end

    # Deterministic variety keyed on the row number, matching CARDS' indexes.
    def answers_for(i)
      {
        "1" => { "type" => "multiple_choice",
                 "value" => CARDS[1]["options"][i % 4] },
        "2" => { "type" => "rating", "value" => 1 + (i % 5) },
        "3" => { "type" => "multiple_choice",
                 "value" => CARDS[3]["options"][i % 3] },
        "4" => { "type" => "open_ended",
                 "value" => "Load-test answer #{i % 17}" },
        "5" => { "type" => "rating", "value" => 1 + ((i / 3) % 5) }
      }
    end
  end
end
