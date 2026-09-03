# The leaderboard's standings: token totals per identity, in rank order.
#
# Each entry carries two things: `total`, the number the board RANKS BY —
# the sum of every token type under the survey's default ("all"), or one type
# alone when the creator picked `leaderboard_rank_by` — and `totals`, every
# declared type's total for the row's breakdown. token_totals is a JSON
# column, so summing happens Ruby-side (a SQL SUM over JSON isn't portable
# across sqlite dev/test and Postgres prod); batched like
# PlayerController#scores so a big Verto doesn't load its whole response set
# at once. LeaderboardStanding materialises the result.
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

  # → [ { key_digest:, total:, totals:, achieved_at: }, ... ] best rank first.
  #
  # Only completed responses that carry an identity count. Rows from before
  # the feature (or with the leaderboard off) have no digest — keying those by
  # session_token would make every retake its own entry and defeat the retake
  # policies, so they are excluded rather than mis-grouped.
  def standings(survey)
    runs     = Hash.new { |h, k| h[k] = [] }
    rank_by  = survey.leaderboard_rank_by
    type_ids = survey.token_type_ids
    survey.responses.where(status: "completed")
          .select(:id, :player_key_digest, :token_totals, :completed_at, :created_at)
          .find_each(batch_size: 500) do |resp|
      digest = resp.player_key_digest.presence
      next unless digest
      runs[digest] << run_for(resp, rank_by, type_ids)
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
                 .map { |resp| run_for(resp, survey.leaderboard_rank_by, survey.token_type_ids) }
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
  #
  # `totals` follows the same rule per type, so a row's breakdown always
  # describes the run(s) its ranked total came from.
  def entry_for(policy, digest, list)
    case policy
    when "no_redo"
      first = list.first
      { key_digest: digest, total: first[:total], totals: first[:totals], achieved_at: first[:at] }
    when "restart"
      last = list.last
      { key_digest: digest, total: last[:total], totals: last[:totals], achieved_at: last[:at] }
    else
      { key_digest: digest,
        total: list.sum { |r| r[:total] },
        totals: sum_totals(list),
        achieved_at: list.last[:at] }
    end
  end

  # One completed run as the board sees it: the basis total it is ranked by
  # and every declared type's total for the breakdown, from the response's
  # stored token_totals.
  def run_for(resp, rank_by, type_ids)
    raw = resp.token_totals.is_a?(Hash) ? resp.token_totals : {}
    { total: basis_total(raw, rank_by), totals: per_type(raw, type_ids),
      at: resp.completed_at || resp.created_at, id: resp.id }
  end

  # "all" sums every stored key — the original board, byte-identical, so an
  # existing Verto's standings do not move; a type id counts that type alone.
  def basis_total(raw, rank_by)
    rank_by.to_s == "all" ? raw.values.sum(&:to_i) : raw[rank_by.to_s].to_i
  end

  # The declared types only, zero for anything a run never earned.
  def per_type(raw, type_ids)
    Array(type_ids).index_with { |id| raw[id].to_i }
  end

  def sum_totals(list)
    list.each_with_object({}) do |run, acc|
      run[:totals].each { |id, amount| acc[id] = acc.fetch(id, 0) + amount.to_i }
    end
  end
end
