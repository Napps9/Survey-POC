# A respondent's own account: the Vertos they kept.
#
# Outside /play/ deliberately. That path is the service worker's entire scope
# and its HTML is cached for offline use; a signed-in page has no business in a
# shared device's cache. It is also never embedded, which is why its cookie can
# be SameSite=Lax.
class YouController < ApplicationController
  include PlayerAuthentication
  include AggregatesSurveyResults

  allow_unauthenticated_access
  skip_before_action :set_current_organisation
  layout "fullscreen"

  # Signed out is a real state here, not a redirect: there is no sign-in form
  # to send anyone to. The page explains what /you is and how to get one.
  allow_signed_out_players only: :show

  before_action :no_store
  # Only the pages that draw the pill. sign_out and destroy render nothing.
  before_action :set_purse, only: %i[show verto next_up wallet]

  # How many Vertos the wallet pill's hover breakdown shows before handing over
  # to the wallet itself. Five is a peek, not a second wallet — the pill exists
  # to answer "what have I got" in one glance, and a list long enough to scroll
  # would only be the page it links to, rendered worse.
  PURSE_PREVIEW = 5

  def show
    @claims  = kept_claims
    @compare = comparison_availability(@claims)
  end

  # One Verto in the account: the answers they gave, next to everyone else's.
  #
  # :id is a survey id, and it is not a capability — the lookup runs through
  # this player's own claims, so another account's Verto is indistinguishable
  # from one that does not exist.
  def verto
    @claims = kept_claims.select { |c| c.survey_id.to_s == params[:id].to_s }
    return redirect_to you_path, alert: t("you.not_found") if @claims.empty?

    @survey = @claims.first.survey
    # The run their answers come from. Newest, because a retake is what they
    # think now; the piles below still count every run they kept.
    @answered  = @claims.map(&:response).max_by { |r| r.completed_at || r.created_at }
    @piles     = piles_for(@survey, @claims)
    @standing  = standing_for(@survey, @claims)
    @comparison = comparison_for(@survey, @answered)
    @follow_ups = @survey.follow_up_surveys
  end

  # What's next: the Vertos the creators of the ones they kept have pointed at.
  #
  # There is no feed and no ranking. The only fact this app has about a
  # respondent is which Verto they played, so that fact IS the reason, and the
  # reason is on every card — a respondent who cannot see why they are being
  # shown something has been retargeted rather than helped.
  def next_up
    seen = kept_claims.map(&:survey_id).to_set
    @suggestions = kept_claims.flat_map { |claim|
      claim.survey.follow_up_surveys.map { |s| { survey: s, because: claim.survey } }
    }.reject { |row| seen.include?(row[:survey].id) }
     .uniq { |row| row[:survey].id }
  end

  # The wallet: one row per Verto, and one number that spans them.
  #
  # The rows are the purse's, so the pill's total and this page's total are one
  # computation and cannot disagree; the standing is added here and only here,
  # because it costs a query per row and the pill has no use for it.
  def wallet
    @rows = @purse_rows.map do |row|
      row.merge(standing: standing_for(row[:survey], row[:claims]))
    end
    @total = @purse_total
    @organisations = @rows.map { |row| row[:survey].organisation_id }.uniq.size
  end

  def sign_out
    terminate_player_session
    redirect_to you_path, notice: t("you.signed_out")
  end

  # Self-service erasure. The account, its sessions, its outstanding links and
  # its claims — never the pseudonymous Response rows, which are the creator's
  # research data and are not this person's to delete from here. See
  # docs/DATA_RETENTION.md.
  def destroy
    player = current_player
    terminate_player_session
    player.destroy
    redirect_to you_path, notice: t("you.deleted")
  end

  private

  # Why each listed Verto can't be compared yet — said on the LIST, so nobody
  # has to open a Verto to find out there is nothing to see in it. Two gates,
  # and a respondent has no way to tell them apart from the outside:
  #
  #   :closed  — show_results_comparison is the creator's switch and defaults
  #              to false, so this is the commonest answer by a distance.
  #   { have: } — under MIN_REGION_SAMPLE_SIZE. Deliberately says the floor and
  #              the count rather than "not enough yet": a respondent who can
  #              see it is 2 of 5 knows to come back, and one who is told
  #              "soon" learns nothing and asks support instead.
  #   :ready   — nothing is drawn. The row already links to the comparison.
  #
  # One grouped COUNT for the whole list, not one per row: this runs on the
  # page that lists every Verto an account holds.
  def comparison_availability(claims)
    surveys = claims.map(&:survey).uniq
    answered = Response.where(survey_id: surveys.map(&:id), answered: true)
                       .group(:survey_id).count

    surveys.each_with_object({}) do |survey, out|
      out[survey.id] =
        if !survey.compare_results?
          :closed
        elsif answered[survey.id].to_i < Response::MIN_REGION_SAMPLE_SIZE
          { have: answered[survey.id].to_i }
        else
          :ready
        end
    end
  end

  # What the account has collected, on every page rather than only the wallet:
  # the pill in the corner carries the total everywhere, and its hover
  # breakdown carries the first PURSE_PREVIEW rows.
  #
  # Built from the same rows the wallet renders, deliberately. A pill showing a
  # number the page behind it doesn't agree with is worse than no pill.
  def set_purse
    @purse_rows  = token_rows
    @purse_total = @purse_rows.sum { |row| row[:piles].sum { |p| p[:amount] } }
  end

  # One row per Verto that awarded anything, newest-answered first.
  #
  # group_by preserves first-seen order, so the rows keep kept_claims' own
  # ordering. A Verto that awarded nothing is not a row: an empty pile is not a
  # holding, and listing it would pad the wallet with Vertos that have nothing
  # to show.
  def token_rows
    kept_claims.group_by(&:survey_id).filter_map do |_id, claims|
      survey = claims.first.survey
      piles  = piles_for(survey, claims)
      next if piles.empty?

      { survey: survey, claims: claims, piles: piles }
    end
  end

  # Every Verto this account holds, newest first, minus the ones whose Verto has
  # been deleted since. Shared by every page and by the pill in the corner, so
  # they can never disagree about what the account contains — the header saying
  # "3" and the list showing 2 is the one thing that would make a respondent
  # trust neither.
  #
  # Memoised because the purse now needs it on every action alongside whatever
  # the action itself wanted, and it is the page's one real query.
  def kept_claims
    @kept_claims ||=
      if player_signed_in?
        current_player.player_claims
                      .includes(:response, survey: :organisation)
                      .newest_first
                      .reject { |c| c.survey.nil? || c.survey.deleted_at.present? }
                      .sort_by { |c| -played_at(c).to_i }
      else
        []
      end
  end

  # Ordered by when they ANSWERED, not when the claim was written — both pages
  # show the played date, and a device key can attach a Verto from March to an
  # account today, which under claimed_at order puts an old Verto at the top of
  # a list displaying an old date. It also makes the order deterministic when
  # several Vertos are claimed by one sign-in, which is the ordinary case: they
  # all share a claimed_at to the microsecond.
  def played_at(claim)
    claim.response.completed_at || claim.response.created_at || claim.claimed_at
  end

  # What they collected on ONE Verto, built inside that Verto's own row and
  # never merged with another's.
  #
  # Token ids are not unique across Vertos: Survey#duplicate! copies
  # token_types verbatim and sanitize_token_types passes creator-supplied ids
  # straight through, so two Vertos routinely both use "gold" for two entirely
  # different things. The key is therefore (survey_id, token_id) — expressed
  # here by only ever summing within one survey's claims and reading the names
  # and icons off that survey's own token_types.
  #
  # The amounts come from responses.token_totals, which is a stored column
  # written when the run was saved. That makes a pile a SNAPSHOT of what they
  # collected, not a live recomputation: a creator who re-tunes their awards
  # next month changes what future respondents earn, not what this person did.
  # (The rank below is the opposite, and deliberately — see standing_for.)
  def piles_for(survey, claims)
    collected = Hash.new(0)
    claims.each do |claim|
      claim.response.token_totals.to_h.each { |id, n| collected[id.to_s] += n.to_i }
    end

    Array(survey.token_types).filter_map do |type|
      amount = collected[type["id"].to_s]
      next if amount.zero?

      { id: type["id"], icon: type["icon"], name: type["name"], amount: amount }
    end
  end

  # Where they stand on that Verto's own board, wearing that Verto's own
  # anonymous name — per-Verto and un-merged, including the fact that the name
  # differs from one Verto to the next. There is no cross-Verto ranking
  # anywhere in this account: award sizes are a creator's free choice, so a
  # league table across Vertos would only measure whose Verto you happened to
  # play.
  #
  # nil in three ordinary cases, all of which the page simply renders without:
  # the Verto has no board, the run carries no durable identity (the account
  # writes none — see PlayerController#join — so this is only ever a digest the
  # player itself minted while a board was on), or the board has not caught up
  # with them yet.
  #
  # Unlike the piles, a rank is LIVE, and has to be: it describes a population
  # that is still answering, and a frozen one would be wrong by morning.
  def standing_for(survey, claims)
    return nil unless survey.leaderboard_active?

    digest = claims.filter_map { |c| c.response.player_key_digest }.first
    return nil if digest.nil?

    entry = TokenLeaderboard.entry_for_digest(survey, digest)
    return nil if entry.nil?

    total = survey.leaderboard_standings.count
    total += 1 unless survey.leaderboard_standings.exists?(key_digest: digest)
    { name: PlayerAlias.ensure_for!(survey: survey, key_digest: digest).anon_name,
      rank: LeaderboardStanding.rank_of(survey, total: entry[:total],
                                        achieved_at: entry[:achieved_at], key_digest: digest),
      of:   total }
  end

  # Their answers next to everyone else's — the same rows the player draws at
  # the end of the Verto, off the same cached payload, so opening this page
  # right after finishing costs nothing and shows the same numbers.
  #
  # Three states, and the two that show less are not error cases:
  #
  #   :off        — show_results_comparison is the creator's switch and stays
  #                 theirs. The account keeps the Verto either way; it just has
  #                 less to show. Read off the SURVEY rather than through
  #                 play_settings: a SurveyLink's override is about the cohort
  #                 that link was sent to, and there is no link here.
  #   :suppressed — under MIN_REGION_SAMPLE_SIZE the whole payload is refused,
  #                 exactly as #results refuses it. On a Verto with one or two
  #                 responders the "comparison" IS the other respondent's
  #                 answers. An account must not become a way around that.
  #   :rows       — a row per question, with their own answer marked.
  def comparison_for(survey, response)
    return { state: :off } unless survey.compare_results?

    payload = cached_survey_aggregate(:results, survey) do
      responses = survey.responses.where(answered: true)
      total     = responses.count
      if total < Response::MIN_REGION_SAMPLE_SIZE
        { suppressed: true, total_responses: total, results: [] }
      else
        { total_responses: total, results: aggregate_rows(survey, responses) }
      end
    end

    return { state: :suppressed, total: payload[:total_responses] } if payload[:suppressed]

    { state: :rows, total: payload[:total_responses],
      rows: comparison_rows(payload[:results], response) }
  end

  # Pair each aggregated card with what THIS person said. Rows the account can
  # draw a fair bar for are the option-shaped ones; for the rest — a written
  # answer, a rating, a ranking — their own answer is shown without a
  # distribution rather than with a chart that means something else.
  def comparison_rows(results, response)
    answers = response.answers.to_h
    Array(results).filter_map do |row|
      mine = answers[row[:index].to_s]
      mine = mine["value"] if mine.is_a?(Hash)
      next if mine.nil? || mine == "" || mine == false

      options = Array(row[:options])
      counts  = row[:counts].to_h
      total   = row[:total].to_i
      bars = if options.any? && total.positive?
        options.map do |option|
          n = counts[option].to_i
          { label: option, pct: (n * 100.0 / total).round,
            mine: Array(mine).map(&:to_s).include?(option.to_s) }
        end
      else
        []
      end

      { prompt: row[:prompt], mine: Array(mine).join(", "), bars: bars }
    end
  end

  # aggregate_rows lives on PlayerController and carries the tap-card scale the
  # client needs; here the rows are rendered server-side and only the option
  # tallies are used, so this is the same shape without that extra.
  def aggregate_rows(survey, responses)
    aggregate_results(Array(survey.cards), responses).map.with_index do |row, idx|
      { index: idx, type: row[:type],
        prompt: row[:card]["text"] || row[:card]["prompt"] || row[:card]["title"],
        options: row[:card]["options"], total: row[:total], counts: row[:counts] }
    end
  end

  # A page listing what one person has answered must not be written to a
  # shared browser's disk cache. Same header Comms::TrackingController sets.
  def no_store
    response.headers["Cache-Control"] = "no-store"
  end
end
