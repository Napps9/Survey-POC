# Definitions for the starter Blazer queries shown to VertoNow staff, plus the
# create/refresh logic. db/seeds/blazer_starter_queries.rb (fresh installs) and
# the data migration that ships query changes both go through here, so the SQL
# can never drift between them.
#
# Every query excludes "internal" organisations — VertoNow's own test orgs,
# flagged via organisations.internal — so the dashboards reflect real customer
# usage. Sign-ups and logins are filtered by the same rule: a user counts as
# internal when they belong to an internal org (see INTERNAL_MEMBERS).
#
# SQL targets PostgreSQL (production). It won't run as-is against the dev/test
# SQLite database (date_trunc / FILTER / interval) — Blazer is a production tool.
module BlazerStarterQueries
  module_function

  # Users who belong to an internal org — excluded from user/login/sign-up counts.
  INTERNAL_MEMBERS =
    "SELECT m.user_id FROM memberships m " \
    "JOIN organisations o ON o.id = m.organisation_id WHERE o.internal"

  DEFINITIONS = [
    # ── Usage: how the platform is being used ──────────────────────────────
    {
      name: "Usage — Platform overview",
      description: "Headline counts across all organisations (excludes internal).",
      statement: <<~SQL
        SELECT
          (SELECT COUNT(*) FROM organisations WHERE NOT internal)                AS organisations,
          (SELECT COUNT(*) FROM users WHERE id NOT IN (#{INTERNAL_MEMBERS}))     AS users,
          (SELECT COUNT(*) FROM surveys s
             JOIN organisations o ON o.id = s.organisation_id
             WHERE s.deleted_at IS NULL AND NOT o.internal)                      AS vertos,
          (SELECT COUNT(*) FROM surveys s
             JOIN organisations o ON o.id = s.organisation_id
             WHERE s.published_at IS NOT NULL AND NOT o.internal)                AS published_vertos,
          (SELECT COUNT(*) FROM responses r
             JOIN surveys s       ON s.id = r.survey_id
             JOIN organisations o ON o.id = s.organisation_id
             WHERE NOT o.internal)                                              AS responses,
          (SELECT COUNT(*) FROM responses r
             JOIN surveys s       ON s.id = r.survey_id
             JOIN organisations o ON o.id = s.organisation_id
             WHERE r.status = 'completed' AND NOT o.internal)                   AS completed_responses
      SQL
    },
    {
      name: "Usage — New organisations by week",
      description: "Org sign-ups over time (excludes internal).",
      statement: <<~SQL
        SELECT date_trunc('week', created_at)::date AS week, COUNT(*) AS organisations
        FROM organisations
        WHERE NOT internal
        GROUP BY 1 ORDER BY 1
      SQL
    },
    {
      name: "Usage — New users by week",
      description: "User sign-ups over time (excludes internal staff).",
      statement: <<~SQL
        SELECT date_trunc('week', created_at)::date AS week, COUNT(*) AS users
        FROM users
        WHERE id NOT IN (#{INTERNAL_MEMBERS})
        GROUP BY 1 ORDER BY 1
      SQL
    },
    {
      name: "Usage — Logins by day (last 30 days)",
      description: "One row per session created — a proxy for daily active logins (excludes internal staff).",
      statement: <<~SQL
        SELECT date_trunc('day', created_at)::date AS day, COUNT(*) AS logins
        FROM sessions
        WHERE created_at > now() - interval '30 days'
          AND user_id NOT IN (#{INTERNAL_MEMBERS})
        GROUP BY 1 ORDER BY 1
      SQL
    },
    {
      name: "Usage — Vertos created vs published by week",
      description: "Authoring activity and how much of it goes live (excludes internal).",
      statement: <<~SQL
        SELECT date_trunc('week', s.created_at)::date AS week,
               COUNT(*)                                         AS created,
               COUNT(*) FILTER (WHERE s.published_at IS NOT NULL) AS published
        FROM surveys s
        JOIN organisations o ON o.id = s.organisation_id
        WHERE s.deleted_at IS NULL AND NOT o.internal
        GROUP BY 1 ORDER BY 1
      SQL
    },
    {
      name: "Usage — Most active organisations (last 30 days)",
      description: "Orgs ranked by responses collected in the last 30 days (excludes internal).",
      statement: <<~SQL
        SELECT o.name AS organisation, COUNT(r.id) AS responses_30d
        FROM organisations o
        JOIN surveys   s ON s.organisation_id = o.id
        JOIN responses r ON r.survey_id = s.id
        WHERE r.created_at > now() - interval '30 days'
          AND NOT o.internal
        GROUP BY o.name
        ORDER BY responses_30d DESC
      SQL
    },

    # ── Collected data: what respondents are telling you ───────────────────
    {
      name: "Data — Responses by day (last 30 days)",
      description: "Completed vs started (drop-off) responses over time (excludes internal).",
      statement: <<~SQL
        SELECT date_trunc('day', r.created_at)::date AS day,
               COUNT(*) FILTER (WHERE r.status = 'completed') AS completed,
               COUNT(*) FILTER (WHERE r.status = 'started')   AS started
        FROM responses r
        JOIN surveys s       ON s.id = r.survey_id
        JOIN organisations o ON o.id = s.organisation_id
        WHERE r.created_at > now() - interval '30 days'
          AND NOT o.internal
        GROUP BY 1 ORDER BY 1
      SQL
    },
    {
      name: "Data — Completion rate by Verto",
      description: "Total vs completed responses, with completion %, per Verto (excludes internal).",
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
        WHERE NOT o.internal
        GROUP BY o.name, s.title
        ORDER BY total DESC
      SQL
    },
    {
      name: "Data — Responses by country",
      description: "Where completed responses come from (self-declared region; excludes internal).",
      statement: <<~SQL
        SELECT COALESCE(r.region_country, 'Unknown') AS country, COUNT(*) AS responses
        FROM responses r
        JOIN surveys s       ON s.id = r.survey_id
        JOIN organisations o ON o.id = s.organisation_id
        WHERE r.status = 'completed' AND NOT o.internal
        GROUP BY 1 ORDER BY responses DESC
      SQL
    },
    {
      name: "Data — Responses by language",
      description: "Locale respondents answered in (excludes internal).",
      statement: <<~SQL
        SELECT COALESCE(r.locale, 'unknown') AS locale, COUNT(*) AS responses
        FROM responses r
        JOIN surveys s       ON s.id = r.survey_id
        JOIN organisations o ON o.id = s.organisation_id
        WHERE r.status = 'completed' AND NOT o.internal
        GROUP BY 1 ORDER BY responses DESC
      SQL
    },
    {
      name: "Data — Top Vertos by completed responses",
      description: "Your highest-volume Vertos across all organisations (excludes internal).",
      statement: <<~SQL
        SELECT o.name AS organisation, s.title AS verto, COUNT(r.id) AS completed_responses
        FROM responses r
        JOIN surveys s       ON s.id = r.survey_id
        JOIN organisations o ON o.id = s.organisation_id
        WHERE r.status = 'completed' AND NOT o.internal
        GROUP BY o.name, s.title
        ORDER BY completed_responses DESC
      SQL
    },

    # ── Content: the actual questions creators wrote and answers players gave ──
    {
      name: "Content — Questions in a Verto",
      description: "Every card/question in one Verto, in order. Choose a Verto with the {verto_id} dropdown.",
      statement: <<~SQL
        SELECT card.ord - 1           AS position,
               card.elem ->> 'type'   AS type,
               card.elem ->> 'text'   AS question,
               card.elem -> 'options' AS options
        FROM surveys s
        JOIN organisations o ON o.id = s.organisation_id
        CROSS JOIN LATERAL json_array_elements(s.cards) WITH ORDINALITY AS card(elem, ord)
        WHERE s.id = {verto_id} AND NOT o.internal
        ORDER BY position
      SQL
    },
    {
      name: "Content — Answers in a Verto",
      description: "Each player's answer paired with its question, for one Verto. Choose a Verto with the {verto_id} dropdown. Multi-select answers show as a JSON list; free-text shows under answer/other.",
      statement: <<~SQL
        SELECT r.id                            AS response_id,
               r.status,
               COALESCE(r.region_country, '')  AS country,
               r.locale,
               card.ord - 1                    AS position,
               card.elem ->> 'text'            AS question,
               (r.answers -> (card.ord - 1)::text) ->> 'value' AS answer,
               (r.answers -> (card.ord - 1)::text) ->> 'other' AS other
        FROM responses r
        JOIN surveys s       ON s.id = r.survey_id
        JOIN organisations o ON o.id = s.organisation_id
        CROSS JOIN LATERAL json_array_elements(s.cards) WITH ORDINALITY AS card(elem, ord)
        WHERE s.id = {verto_id} AND NOT o.internal
          AND (r.answers -> (card.ord - 1)::text) IS NOT NULL
        ORDER BY r.id, position
      SQL
    },

    # ── Retention: do creators keep creating? ──────────────────────────────
    {
      name: "Usage — Verto-creator retention (weekly cohorts)",
      description: "Weekly retention of Verto-creating organisations. Each row is the week an org first " \
                   "created a Verto; week_0 is that cohort's size, and week_1..6 count how many of the " \
                   "cohort created another Verto that many weeks later. Org-level — Vertos aren't " \
                   "attributed to individual users. Excludes internal orgs.",
      statement: <<~SQL
        WITH creator_weeks AS (
          SELECT s.organisation_id AS org_id,
                 date_trunc('week', s.created_at)::date AS active_week
          FROM surveys s
          JOIN organisations o ON o.id = s.organisation_id
          WHERE s.deleted_at IS NULL AND NOT o.internal
          GROUP BY 1, 2
        ),
        cohort AS (
          SELECT org_id, MIN(active_week) AS cohort_week
          FROM creator_weeks
          GROUP BY org_id
        ),
        activity AS (
          SELECT c.cohort_week, cw.org_id,
                 ((cw.active_week - c.cohort_week) / 7)::int AS weeks_since
          FROM cohort c
          JOIN creator_weeks cw ON cw.org_id = c.org_id
        )
        SELECT cohort_week,
               COUNT(DISTINCT org_id) FILTER (WHERE weeks_since = 0) AS week_0,
               COUNT(DISTINCT org_id) FILTER (WHERE weeks_since = 1) AS week_1,
               COUNT(DISTINCT org_id) FILTER (WHERE weeks_since = 2) AS week_2,
               COUNT(DISTINCT org_id) FILTER (WHERE weeks_since = 3) AS week_3,
               COUNT(DISTINCT org_id) FILTER (WHERE weeks_since = 4) AS week_4,
               COUNT(DISTINCT org_id) FILTER (WHERE weeks_since = 5) AS week_5,
               COUNT(DISTINCT org_id) FILTER (WHERE weeks_since = 6) AS week_6
        FROM activity
        GROUP BY cohort_week
        ORDER BY cohort_week
      SQL
    }
  ].freeze

  # Create any starter queries that don't exist yet; never touch existing rows,
  # so edits the team makes in Blazer are preserved. Used by db/seeds.
  def create_missing!
    upsert!(update_existing: false)
  end

  # Create missing queries and refresh the SQL/description of existing ones to
  # match DEFINITIONS. Used by the data migration / rake task to ship changes.
  def resync!
    upsert!(update_existing: true)
  end

  # Returns the number of queries created or updated.
  def upsert!(update_existing:)
    return 0 unless defined?(Blazer::Query) && Blazer::Query.table_exists?

    DEFINITIONS.count do |attrs|
      query     = Blazer::Query.find_or_initialize_by(name: attrs[:name])
      statement = attrs[:statement].strip

      if query.new_record?
        query.update!(data_source: "main", description: attrs[:description], statement: statement)
        true
      elsif update_existing && (query.statement != statement || query.description != attrs[:description])
        query.update!(description: attrs[:description], statement: statement)
        true
      else
        false
      end
    end
  end
end
