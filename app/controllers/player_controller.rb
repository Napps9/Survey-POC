class PlayerController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"
  skip_before_action :require_authentication
  skip_before_action :set_current_organisation
  protect_from_forgery with: :null_session, only: [ :submit, :progress ]

  # Public, unauthenticated write endpoints — cap per-IP request rate so one
  # source can't flood responses (results poisoning / storage abuse). Limits are
  # deliberately high: a real respondent sends one submit and a handful of
  # progress pings, but many respondents can legitimately share one public IP
  # (event/venue Wi‑Fi behind NAT), so these only stop pathological floods.
  # Raise them if you run large single-IP events. No-op in test (null cache).
  rate_limit to: 60, within: 1.minute, only: :submit,
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  rate_limit to: 300, within: 1.minute, only: [ :progress, :grade ],
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }

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
    # Quiz answers are immutable once committed — fold the incoming payload over
    # what's already stored so an already-answered graded card can't be changed.
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    # NB: the status column defaults to "completed", so a freshly initialized
    # record already reads "completed" — only preserve it for rows already saved
    # as completed (a late progress ping after submit), otherwise mark "started".
    resp.status  = "started" unless resp.persisted? && resp.status == "completed"
    apply_quiz_score(resp)
    resp.save!
    render json: { ok: true, session_token: token }
  rescue => e
    Rails.logger.error("[PlayerController##{action_name}] #{e.class}: #{e.message}")
    render json: { ok: false, error: "Something went wrong saving your response." }, status: :unprocessable_entity
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
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    resp.status  = "completed"
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    apply_quiz_score(resp)
    resp.save!
    payload = { ok: true }
    payload.merge!(score: resp.score, max: resp.quiz_max) if @survey.quiz?
    render json: payload
  rescue => e
    Rails.logger.error("[PlayerController##{action_name}] #{e.class}: #{e.message}")
    render json: { ok: false, error: "Something went wrong saving your response." }, status: :unprocessable_entity
  end

  # Quiz: record + grade one card as the player advances, returning that card's
  # verdict so the player can reveal it. Doubles as the progress save for quizzes
  # (it records the whole payload, immutably for already-answered graded cards).
  # The correct answer is only ever revealed for a card the session has actually
  # committed an answer to — so it can't be peeked before answering.
  def grade
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    return render json: { ok: false, error: "Not a quiz" }, status: :forbidden unless @survey.quiz?

    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    idx   = data["card_index"].to_i
    resp  = Response.find_or_initialize_by(session_token: token)
    resp.survey       ||= @survey
    resp.survey_share ||= @survey_share
    apply_region(resp, data)
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    resp.status  = "started" unless resp.persisted? && resp.status == "completed"
    apply_quiz_score(resp)
    resp.save!

    base = { ok: true, session_token: token, score: resp.score, max: resp.quiz_max }
    card = Array(@survey.cards)[idx]
    stored = resp.answers[idx.to_s]
    if card && QuizGrading.graded?(card) && answered?(stored)
      render json: base.merge(
        graded: true,
        correct: QuizGrading.correct?(card, stored["value"]),
        correct_answer: QuizGrading.correct_display(card),
        explanation: card["explanation"].to_s
      )
    else
      # Measurement card, unknown index, or no committed answer yet — record
      # only, reveal nothing.
      render json: base.merge(graded: false)
    end
  rescue => e
    Rails.logger.error("[PlayerController##{action_name}] #{e.class}: #{e.message}")
    render json: { ok: false, error: "Something went wrong scoring your answer." }, status: :unprocessable_entity
  end

  # Quiz: the session's already-committed graded cards, so a reload re-locks and
  # re-reveals them (refresh-proof no-redo). Resolved by the client's session
  # token; these answers are already committed, so revealing them is safe.
  def quiz_state
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    return render json: { ok: true, quiz: false } unless @survey.quiz?

    token = params[:session_token].to_s
    resp  = token.present? ? @survey.responses.find_by(session_token: token) : nil
    answered = {}
    if resp
      Array(@survey.cards).each_with_index do |card, idx|
        next unless QuizGrading.graded?(card)
        ans = (resp.answers || {})[idx.to_s]
        next unless answered?(ans)
        answered[idx.to_s] = {
          value:          ans["value"],
          correct:        QuizGrading.correct?(card, ans["value"]),
          correct_answer: QuizGrading.correct_display(card),
          explanation:    card["explanation"].to_s
        }
      end
    end
    render json: { ok: true, quiz: true, score: resp&.score,
                   max: resp&.quiz_max || QuizGrading.graded_indices(@survey.cards).size,
                   answered: answered }
  end

  # Quiz: anonymous score distribution across completed responses, so a player
  # can see how they did versus everyone else (no identities — a histogram and
  # per-question correct-rate).
  def scores
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    return render json: { ok: false, error: "Not a quiz" }, status: :forbidden unless @survey.quiz?

    completed = @survey.responses.where(status: "completed").where.not(score: nil).to_a
    values    = completed.map(&:score)
    max       = QuizGrading.graded_indices(@survey.cards).size
    total     = values.size
    avg       = total.positive? ? (values.sum.to_f / total).round(1) : 0.0
    dist      = Hash.new(0).tap { |h| values.each { |s| h[s] += 1 } }

    per_question = Array(@survey.cards).each_with_index.filter_map do |card, idx|
      next unless QuizGrading.graded?(card)
      n = completed.count { |r| QuizGrading.correct?(card, (r.answers || {})[idx.to_s]&.dig("value")) }
      { index: idx, prompt: card["text"], correct: n,
        pct: total.positive? ? (n * 100.0 / total).round : 0 }
    end

    render json: { ok: true, total:, max:, average: avg,
                   distribution: (0..max).map { |s| { score: s, count: dist[s] } },
                   per_question: }
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
    unless @survey.survey_region_links.exists? || @survey.ask_region?
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

  # The answers already persisted for a response (empty for a brand-new row).
  def stored_answers(resp)
    resp.persisted? && resp.answers.is_a?(Hash) ? resp.answers : {}
  end

  # Anti-cheat for quizzes: a graded card that already holds a committed answer
  # is locked — its stored value always wins over anything in the new payload.
  # Non-graded (measurement) cards and not-yet-answered cards take the incoming
  # value as normal. Non-quiz Vertos merge nothing (incoming wins outright).
  def locked_merge(stored, incoming)
    incoming = incoming.is_a?(Hash) ? incoming : {}
    return incoming unless @survey.quiz?
    stored = stored.is_a?(Hash) ? stored : {}
    merged = incoming.dup
    Array(@survey.cards).each_with_index do |card, idx|
      next unless QuizGrading.graded?(card)
      key = idx.to_s
      merged[key] = stored[key] if answered?(stored[key])
    end
    merged
  end

  # Whether an answer hash holds a real response (a value, or free-text Other).
  def answered?(ans)
    return false unless ans.is_a?(Hash)
    return true if ans["other"].to_s.strip != ""
    v = ans["value"]
    return v.any? if v.is_a?(Array)
    !(v.nil? || (v.is_a?(String) && v.strip.empty?))
  end

  # Cache the server-computed score on quiz responses so "how you compare" is a
  # cheap read; a no-op for non-quiz Vertos.
  def apply_quiz_score(resp)
    return unless @survey.quiz?
    result = QuizGrading.score(@survey.cards, resp.answers)
    resp.score    = result[:score]
    resp.quiz_max = result[:max]
  end

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
  # link the respondent arrived through, or their explicit pick — never
  # inferred location. An opt-out in the payload always wins. Self-declared
  # values are honoured when they match one of the Verto's region tags, or —
  # in ask-players mode — any valid country plus a short free-text area.
  def apply_region(resp, data)
    country = data["region_country"].to_s.upcase.presence
    label   = data["region_label"].to_s.strip.first(60).presence

    if data["region_opt_out"]
      link = nil
    elsif @region_link
      link = @region_link
    else
      link = country && @survey.survey_region_links.find_by(country_code: country, label: label)
    end

    if link
      resp.survey_region_link = link
      resp.region_country     = link.country_code
      resp.region_label       = link.label
    elsif !data["region_opt_out"] && @survey.ask_region? && country && WorldRegions.valid?(country)
      resp.survey_region_link = nil
      resp.region_country     = country
      resp.region_label       = label
    else
      resp.survey_region_link = nil
      resp.region_country     = nil
      resp.region_label       = nil
    end
  end

  # The Verto content language to render: an explicit ?lang=, else the
  # respondent's UI locale if the Verto has it, else the Verto's primary.
  def resolve_play_locale
    @survey.display_locale_for(params[:lang], Current.locale)
  end

  def load_survey_and_share
    token = params[:token]
    # without_report_text: the player never reads the large AI summary/report
    # columns, so skip loading them into the row on every public play request.
    if (share = SurveyShare.find_by(share_token: token))
      @survey_share = share
      @survey = Survey.without_report_text.find_by(id: share.survey_id)
    elsif (region_link = SurveyRegionLink.find_by(token: token))
      @region_link = region_link
      @survey = Survey.without_report_text.find_by(id: region_link.survey_id)
    else
      @survey = Survey.without_report_text.find_by(publish_token: token)
    end
  end
end
