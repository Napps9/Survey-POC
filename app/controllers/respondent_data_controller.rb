# GDPR data-subject rights for one respondent of one Verto (P0-7).
#
# The creator is the data controller — a respondent's request reaches them, not
# us — so this is a creator-facing tool rather than a self-service portal. It
# couldn't be self-service anyway: a respondent's session token lives in
# sessionStorage and is gone once the tab closes, so most respondents hold no
# durable handle on their own row. See docs/DATA_RETENTION.md.
#
# Admin-only, and scoped to the current organisation's Vertos, because it
# returns a named individual's answers rather than the aggregate every other
# results view is careful to keep anonymous.
class RespondentDataController < ApplicationController
  before_action :require_admin!
  before_action :set_survey

  # The lookup form, plus the matching responses when a query was given.
  def show
    @session_token   = params[:session_token].to_s.strip
    @respondent_code = params[:respondent_code].to_s.strip
    @searched        = @session_token.present? || @respondent_code.present?
    @responses       = @searched ? lookup.order(created_at: :asc).to_a : []
  end

  # Article 15 / 20: everything held about them, as JSON they can be sent.
  def export
    responses = lookup.order(created_at: :asc)
    if responses.empty?
      return redirect_to survey_respondent_data_path(@survey),
                         alert: t("respondent_data.not_found")
    end

    data = RespondentDataExport.call(survey: @survey, responses: responses)
    send_data JSON.pretty_generate(data),
              filename: "verto-#{@survey.id}-respondent-data.json",
              type: "application/json",
              disposition: "attachment"
  end

  # Article 17: erasure. A hard delete rather than an anonymisation pass,
  # because erasure is what the right actually is — leaving a stripped row
  # behind would still be personal data if it could be re-linked, and a
  # half-measure is the kind of thing that reads fine until a regulator asks.
  #
  # The cost is honest: response counts drop, and any cached summary or report
  # keyed to the old count regenerates on next view.
  def destroy
    responses = lookup
    count     = responses.count

    if count.zero?
      return redirect_to survey_respondent_data_path(@survey),
                         alert: t("respondent_data.not_found")
    end

    # Everything the same person left behind goes together: their contact
    # register entry and leaderboard alias hang off the responses'
    # player_key_digest, and erasing the rows while keeping a named contact
    # would gut the erasure it claims to be.
    digests = responses.map(&:player_key_digest).compact.uniq
    if digests.any?
      @survey.contact_details.where(key_digest: digests).delete_all
      @survey.player_aliases.where(key_digest: digests).delete_all
    end
    # The export's Responder name hangs off respondent_code_digest the same
    # way. Purged even when other rows still share the code (a session-token
    # erasure of one run): a stored name is this identity's data, so it goes
    # with the erased rows; survivors re-mint on the next export — losing no
    # rows, and (names being digest-derived) usually the same name.
    code_digests = responses.map(&:respondent_code_digest).compact.uniq
    @survey.respondent_aliases.where(code_digest: code_digests).delete_all if code_digests.any?

    responses.destroy_all
    redirect_to survey_respondent_data_path(@survey),
                notice: t("respondent_data.erased", count: count)
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.find(params[:survey_id])
  end

  def lookup
    RespondentDataExport.lookup(
      survey:          @survey,
      session_token:   params[:session_token],
      respondent_code: params[:respondent_code]
    )
  end
end
