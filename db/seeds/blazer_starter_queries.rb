# Starter Blazer queries for VertoNow staff — a first cut at "seeing usage and
# collected data" across all organisations. Idempotent: created by name only,
# so any edits the team makes in Blazer are preserved on re-seed.
#
# SQL targets PostgreSQL (production). They won't run as-is against the dev/test
# SQLite database (date_trunc / FILTER / interval) — Blazer is a production tool.
return unless defined?(Blazer::Query) && Blazer::Query.table_exists?

STARTER_QUERIES = [
  # ── Usage: how the platform is being used ──────────────────────────────
  {
    name: "Usage — Platform overview",
    description: "Headline counts across all organisations.",
    statement: <<~SQL
      SELECT
        (SELECT COUNT(*) FROM organisations)                              AS organisations,
        (SELECT COUNT(*) FROM users)                                      AS users,
        (SELECT COUNT(*) FROM surveys WHERE deleted_at IS NULL)           AS vertos,
        (SELECT COUNT(*) FROM surveys WHERE published_at IS NOT NULL)     AS published_vertos,
        (SELECT COUNT(*) FROM responses)                                  AS responses,
        (SELECT COUNT(*) FROM responses WHERE status = 'completed')       AS completed_responses
    SQL
  },
  {
    name: "Usage — New organisations by week",
    description: "Org sign-ups over time.",
    statement: <<~SQL
      SELECT date_trunc('week', created_at)::date AS week, COUNT(*) AS organisations
      FROM organisations
      GROUP BY 1 ORDER BY 1
    SQL
  },
  {
    name: "Usage — New users by week",
    description: "User sign-ups over time.",
    statement: <<~SQL
      SELECT date_trunc('week', created_at)::date AS week, COUNT(*) AS users
      FROM users
      GROUP BY 1 ORDER BY 1
    SQL
  },
  {
    name: "Usage — Logins by day (last 30 days)",
    description: "One row per session created — a proxy for daily active logins.",
    statement: <<~SQL
      SELECT date_trunc('day', created_at)::date AS day, COUNT(*) AS logins
      FROM sessions
      WHERE created_at > now() - interval '30 days'
      GROUP BY 1 ORDER BY 1
    SQL
  },
  {
    name: "Usage — Vertos created vs published by week",
    description: "Authoring activity and how much of it goes live.",
    statement: <<~SQL
      SELECT date_trunc('week', created_at)::date AS week,
             COUNT(*)                                   AS created,
             COUNT(*) FILTER (WHERE published_at IS NOT NULL) AS published
      FROM surveys
      WHERE deleted_at IS NULL
      GROUP BY 1 ORDER BY 1
    SQL
  },
  {
    name: "Usage — Most active organisations (last 30 days)",
    description: "Orgs ranked by responses collected in the last 30 days.",
    statement: <<~SQL
      SELECT o.name AS organisation, COUNT(r.id) AS responses_30d
      FROM organisations o
      JOIN surveys   s ON s.organisation_id = o.id
      JOIN responses r ON r.survey_id = s.id
      WHERE r.created_at > now() - interval '30 days'
      GROUP BY o.name
      ORDER BY responses_30d DESC
    SQL
  },

  # ── Collected data: what respondents are telling you ───────────────────
  {
    name: "Data — Responses by day (last 30 days)",
    description: "Completed vs started (drop-off) responses over time.",
    statement: <<~SQL
      SELECT date_trunc('day', created_at)::date AS day,
             COUNT(*) FILTER (WHERE status = 'completed') AS completed,
             COUNT(*) FILTER (WHERE status = 'started')   AS started
      FROM responses
      WHERE created_at > now() - interval '30 days'
      GROUP BY 1 ORDER BY 1
    SQL
  },
  {
    name: "Data — Completion rate by Verto",
    description: "Total vs completed responses, with completion %, per Verto.",
    statement: <<~SQL
      SELECT o.name AS organisation,
             s.title AS verto,
             COUNT(r.id) AS total,
             COUNT(r.id) FILTER (WHERE r.status = 'completed') AS completed,
             ROUND(100.0 * COUNT(r.id) FILTER (WHERE r.status = 'completed')
                   / NULLIF(COUNT(r.id), 0), 1) AS completion_pct
      FROM surveys s
      JOIN organisations o ON o.id = s.organisation_id
      JOIN responses r     ON r.survey_id = s.id
      GROUP BY o.name, s.title
      ORDER BY total DESC
    SQL
  },
  {
    name: "Data — Responses by country",
    description: "Where completed responses come from (self-declared region).",
    statement: <<~SQL
      SELECT COALESCE(region_country, 'Unknown') AS country, COUNT(*) AS responses
      FROM responses
      WHERE status = 'completed'
      GROUP BY 1 ORDER BY responses DESC
    SQL
  },
  {
    name: "Data — Responses by language",
    description: "Locale respondents answered in.",
    statement: <<~SQL
      SELECT COALESCE(locale, 'unknown') AS locale, COUNT(*) AS responses
      FROM responses
      WHERE status = 'completed'
      GROUP BY 1 ORDER BY responses DESC
    SQL
  },
  {
    name: "Data — Top Vertos by completed responses",
    description: "Your highest-volume Vertos across all organisations.",
    statement: <<~SQL
      SELECT o.name AS organisation, s.title AS verto, COUNT(r.id) AS completed_responses
      FROM responses r
      JOIN surveys s       ON s.id = r.survey_id
      JOIN organisations o ON o.id = s.organisation_id
      WHERE r.status = 'completed'
      GROUP BY o.name, s.title
      ORDER BY completed_responses DESC
    SQL
  }
].freeze

created = 0
STARTER_QUERIES.each do |attrs|
  next if Blazer::Query.exists?(name: attrs[:name])

  Blazer::Query.create!(
    name: attrs[:name],
    description: attrs[:description],
    statement: attrs[:statement].strip,
    data_source: "main"
  )
  created += 1
end

puts "Blazer starter queries: #{created} created, #{STARTER_QUERIES.size - created} already present."
