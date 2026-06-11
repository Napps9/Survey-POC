class PlayerController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"
  skip_before_action :require_authentication
  skip_before_action :set_current_organisation
  protect_from_forgery with: :null_session, only: [ :submit, :progress ]

  before_action :load_survey_and_share

  def show
    return render plain: "Survey not found", status: :not_found unless @survey
    return render plain: "This Verto is no longer available.", status: :gone if @survey.deleted?
    @display_locale = resolve_play_locale
  end

  # Partial save while the player is mid-survey, so we can count people who
  # answered at least one question even if they never reach Submit. Idempotent
  # per session_token (a refresh reuses the token) and never downgrades a
  # response that has already been completed.
  def progress
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = Response.find_or_initialize_by(session_token: token)
    resp.survey       ||= @survey
    resp.survey_share ||= @survey_share
    apply_region(resp, data)
    resp.answers = data["answers"] || {}
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    # NB: the status column defaults to "completed", so a freshly initialized
    # record already reads "completed" — only preserve it for rows already saved
    # as completed (a late progress ping after submit), otherwise mark "started".
    resp.status  = "started" unless resp.persisted? && resp.status == "completed"
    resp.save!
    render json: { ok: true, session_token: token }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  def submit
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = Response.find_or_initialize_by(session_token: token)
    resp.survey       ||= @survey
    resp.survey_share ||= @survey_share
    apply_region(resp, data)
    attrs = { answers: data["answers"] || {}, status: "completed" }
    attrs[:locale] = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    resp.update!(attrs)
    render json: { ok: true }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  def results
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    unless @survey.show_results_comparison?
      return render json: { ok: false, error: "Comparison not enabled" }, status: :forbidden
    end

    responses = @survey.responses.where(status: "completed")
    render json: { ok: true, total_responses: responses.count,
                   results: aggregate_rows(responses) }
  end

  # Per-region aggregates for the post-finish map view: one entry per region
  # (country + label) that has at least one completed, region-tagged response.
  def regions
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    unless @survey.survey_region_links.exists?
      return render json: { ok: false, error: "Regions not enabled" }, status: :forbidden
    end

    tagged = @survey.responses.where(status: "completed").where.not(region_country: nil)
    groups = tagged.group_by(&:region_key)
    rows = groups.map do |key, rs|
      sample = rs.first
      {
        id:           key,
        country:      sample.region_country,
        country_name: WorldRegions.name_for(sample.region_country),
        label:        sample.region_label,
        responders:   rs.size,
        results:      aggregate_rows(rs)
      }
    end.sort_by { |r| -r[:responders] }
    render json: { ok: true, total_tagged: tagged.size, regions: rows }
  end

  private

  # The flat row shape the player JS renders comparisons from.
  def aggregate_rows(responses)
    aggregate_results(Array(@survey.cards), responses).map.with_index do |row, idx|
      {
        index:  idx,
        type:   row[:type],
        prompt: row[:card]["text"] || row[:card]["prompt"] || row[:card]["title"],
        options: row[:card]["options"],
        total:  row[:total],
        counts: row[:counts],
        avg:    row[:avg]
      }
    end
  end

  # Region tagging is consent-based and coarse: the region comes from the
  # link the respondent arrived through, or their explicit pick from this
  # Verto's region tags — never inferred location. An opt-out in the payload
  # always wins, and unmatched/absent values leave the response untagged.
  def apply_region(resp, data)
    link =
      if data["region_opt_out"]
        nil
      elsif @region_link
        @region_link
      else
        country = data["region_country"].to_s.upcase.presence
        label   = data["region_label"].to_s.strip.presence
        country && @survey.survey_region_links.find_by(country_code: country, label: label)
      end
    resp.survey_region_link = link
    resp.region_country     = link&.country_code
    resp.region_label       = link&.label
  end

  # The Verto content language to render: an explicit ?lang=, else the
  # respondent's UI locale if the Verto has it, else the Verto's primary.
  def resolve_play_locale
    @survey.display_locale_for(params[:lang], Current.locale)
  end

  def load_survey_and_share
    token = params[:token]
    if (share = SurveyShare.find_by(share_token: token))
      @survey_share = share
      @survey = share.survey
    elsif (region_link = SurveyRegionLink.find_by(token: token))
      @region_link = region_link
      @survey = region_link.survey
    else
      @survey = Survey.find_by(publish_token: token)
    end
  end
end
