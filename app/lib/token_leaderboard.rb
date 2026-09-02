# The leaderboard's standings: token totals per identity, in rank order.
#
# Computed at read time from Response rows — no denormalised standings table
# to drift. token_totals is a JSON column, so summing happens Ruby-side (a SQL
# SUM over JSON isn't portable across sqlite dev/test and Postgres prod);
# batched like PlayerController#scores so a big Verto doesn't load its whole
# response set at once.
#
# Suppression note, deliberate deviation: every other public aggregate
# (#results, #scores, #regions) suppresses below
# Response::MIN_REGION_SAMPLE_SIZE because small cells can identify people.
# Leaderboard rows are anonymous BY CONSTRUCTION — a system-assigned name, a
# number, no answers, no demographics — and a row is attributable only by
# someone who chooses to reveal their own anon name. A two-player board is a
# working board; suppressing it would gut the feature for exactly the small
# Vertos that want it.
module TokenLeaderboard
  module_function

  # → [ { key_digest:, total:, achieved_at: }, ... ] best rank first.
  #
  # Only completed responses that carry an identity count. Rows from before
  # the feature (or with the leaderboard off) have no digest — keying those by
  # session_token would make every retake its own entry and defeat the retake
  # policies, so they are excluded rather than mis-grouped.
  def standings(survey)
    runs = Hash.new { |h, k| h[k] = [] }
    survey.responses.where(status: "completed")
          .select(:id, :player_key_digest, :token_totals, :completed_at, :created_at)
          .find_each(batch_size: 500) do |resp|
      digest = resp.player_key_digest.presence
      next unless digest
      totals = resp.token_totals.is_a?(Hash) ? resp.token_totals : {}
      runs[digest] << { total: totals.values.sum(&:to_i),
                        at: resp.completed_at || resp.created_at,
                        id: resp.id }
    end

    entries = runs.map do |digest, list|
      list.sort_by! { |r| [ r[:at] || Time.at(0), r[:id] ] }
      entry_for(survey.leaderboard_retake_policy, digest, list)
    end

    # Ties go to whoever reached the total first, so a late equal score never
    # jumps an earlier one; the digest tail makes the order fully stable.
    entries.sort_by { |e| [ -e[:total], e[:achieved_at] || Time.at(0), e[:key_digest] ] }
  end

  # One identity's entry computed from THEIR rows only — an indexed per-digest
  # query, not a board scan. Used to splice a fresh finisher into a snapshot
  # whose debounced refresh hasn't landed yet. nil when they have no completed
  # run.
  def entry_for_digest(survey, digest)
    list = survey.responses.where(status: "completed", player_key_digest: digest)
                 .select(:id, :token_totals, :completed_at, :created_at)
                 .map do |resp|
      totals = resp.token_totals.is_a?(Hash) ? resp.token_totals : {}
      { total: totals.values.sum(&:to_i), at: resp.completed_at || resp.created_at, id: resp.id }
    end
    return nil if list.empty?

    list.sort_by! { |r| [ r[:at] || Time.at(0), r[:id] ] }
    entry_for(survey.leaderboard_retake_policy, digest, list)
  end

  # One identity's board entry under the survey's retake policy. `list` is that
  # identity's completed runs, oldest first.
  #
  #   accumulate — retakes add up; the total was "achieved" at the latest run.
  #   no_redo    — the first completed run counts; later rows are stored but
  #                ignored here. Whether a retake is allowed at all is the
  #                survey's `no_retests` rule, refused server-side; this only
  #                decides how the runs that exist score.
  #   restart    — a retake wipes the old score; the latest run counts.
  def entry_for(policy, digest, list)
    case policy
    when "no_redo"
      first = list.first
      { key_digest: digest, total: first[:total], achieved_at: first[:at] }
    when "restart"
      last = list.last
      { key_digest: digest, total: last[:total], achieved_at: last[:at] }
    else
      { key_digest: digest,
        total: list.sum { |r| r[:total] },
        achieved_at: list.last[:at] }
    end
  end
end
