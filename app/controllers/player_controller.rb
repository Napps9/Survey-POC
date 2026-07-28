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
  # Public read endpoints that aggregate over the whole response set — cap them
  # too, so they can't be hammered as a memory-amplification vector. Generous:
  # a respondent hits each once after finishing.
  rate_limit to: 120, within: 1.minute, only: [ :results, :scores, :regions ],
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  # A respondent's autocomplete keystrokes are debounced client-side, so a
  # generous per-minute cap here only guards against a runaway client/bot.
  rate_limit to: 30, within: 1.minute, only: :location_search,
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }

  # Respondents don't pick their browser the way a creator does — they open a
  # link on whatever phone they already own, often an older Android or an iPhone
  # that stopped getting iOS updates. ApplicationController's
  # `allow_browser versions: :modern` (Safari 17.2+, Chrome 120+, Firefox 121+)
  # is a fair bar for the creator studio, but applying it here served a stock
  # "browser not supported" 406 instead of the Verto — which reads to the
  # respondent, and to the creator chasing a low response rate, as a dead link.
  #
  # The floor below is what the player ACTUALLY needs: import-map support. Below
  # that no player JS loads at all and the page is inert, so blocking is honest.
  # Above it, everything else only degrades — a Chrome 89-110 respondent misses
  # some color-mix()/@property styling and still answers every question, which
  # beats being turned away. Gate on what breaks the page, not on what makes it
  # prettiest.
  #
  # Rails registers allow_browser as an anonymous before_action lambda, so there
  # is no callback name to skip_before_action; overriding the private method that
  # lambda calls is how you re-point it at a different version set.
  PLAYER_BROWSER_VERSIONS = {
    safari: 16.4, chrome: 89, firefox: 108, opera: 76, ie: false
  }.freeze

  before_action :load_survey_and_share

  def show
    # A token that resolves nothing is almost always a link shared before the
    # Verto was published (or a typo) — a respondent dead-end either way, so
    # serve a branded explainer instead of a bare error string.
    return render :unavailable, status: :not_found unless @survey
    if @survey.deleted?
      @oops_gone = true
      return render :unavailable, status: :gone
    end
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
    resp  = find_or_init_response(token)
    # Quiz answers are immutable once committed — fold the incoming payload over
    # what's already stored so an already-answered graded card can't be changed.
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    mark_started_unless_completed(resp)
    apply_quiz_score(resp)
    apply_token_totals(resp)
    resp.save!
    render json: { ok: true, session_token: token }
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    render json: { ok: false, error: "Something went wrong saving your response." }, status: :unprocessable_entity
  end

  def submit
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = find_or_init_response(token)
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    resp.status  = "completed"
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    # A respondent who never triggered /progress (a one-card Verto, or a submit
    # replayed from the offline queue after the page was closed) still needs a
    # start stamp, otherwise their duration is unmeasurable.
    stamp_started_metadata(resp)
    resp.completed_at ||= Time.current
    apply_quiz_score(resp)
    apply_token_totals(resp)
    resp.save!
    payload = { ok: true }
    payload.merge!(score: resp.score, max: resp.quiz_max) if @survey.quiz?
    payload.merge!(token_totals: resp.token_totals) if @survey.tokenisation_enabled?
    render json: payload
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    render json: { ok: false, error: "Something went wrong saving your response." }, status: :unprocessable_entity
  end

  # Records the consent gate's agree/decline event, so there's an audit trail
  # of who consented and to what wording — previously agreeConsent()/
  # declineConsent() were pure client-side UI with nothing persisted. The
  # first event for a session wins (a retry/replay never overwrites an
  # already-recorded timestamp), and the snapshot ties the record to the exact
  # consent_text shown at that moment, immune to the creator editing it later.
  def consent
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?

    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = find_or_init_response(token)
    mark_started_unless_completed(resp)
    if data["agreed"]
      resp.consent_agreed_at ||= Time.current
      resp.consent_text_snapshot ||= @survey.consent_text
    else
      resp.consent_declined_at ||= Time.current
      resp.consent_text_snapshot ||= @survey.consent_text
    end
    resp.save!
    render json: { ok: true }
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    render json: { ok: false, error: "Something went wrong recording your response." }, status: :unprocessable_entity
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
    resp  = find_or_init_response(token)
    first_time = !answered?(stored_answers(resp)[idx.to_s])
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    ai_normalize_open_ended_answer!(resp, idx) if first_time
    sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    mark_started_unless_completed(resp)
    apply_quiz_score(resp)
    apply_token_totals(resp)
    resp.save!

    base = { ok: true, session_token: token, score: resp.score, max: resp.quiz_max }
    base[:token_totals] = resp.token_totals if @survey.tokenisation_enabled?
    card = Array(@survey.cards)[idx]
    stored = resp.answers[idx.to_s]
    if card && QuizGrading.graded?(card) && answered?(stored)
      render json: base.merge(
        graded: true,
        correct: QuizGrading.correct?(card, stored["value"]),
        # correct_answer stays CANONICAL (source-language) on purpose: the player
        # matches it against the stored option values to tint the right/wrong
        # picks, so a translated label here would break the reveal highlighting.
        # The explanation is free prose nobody compares against, so it can — and
        # should — come back in the respondent's language.
        correct_answer: QuizGrading.correct_display(card),
        explanation: localized_explanation(card, resp.locale)
      )
    else
      # Measurement card, unknown index, or no committed answer yet — record
      # only, reveal nothing.
      render json: base.merge(graded: false)
    end
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
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

    max    = QuizGrading.graded_indices(@survey.cards).size
    graded = Array(@survey.cards).each_with_index.select { |card, _idx| QuizGrading.graded?(card) }

    # One batched pass: score histogram, total/average, and per-question correct
    # counts together — instead of loading every scored response into memory and
    # re-scanning the set once per graded card.
    dist        = Hash.new(0)
    correct_by  = Hash.new(0)
    total       = 0
    score_sum   = 0
    @survey.responses.where(status: "completed").where.not(score: nil)
      .select(:id, :score, :answers).find_each(batch_size: 500) do |r|
        total     += 1
        score_sum += r.score
        dist[r.score] += 1
        answers = r.answers || {}
        graded.each do |card, idx|
          correct_by[idx] += 1 if QuizGrading.correct?(card, answers[idx.to_s]&.dig("value"))
        end
      end
    avg = total.positive? ? (score_sum.to_f / total).round(1) : 0.0

    per_question = graded.map do |card, idx|
      { index: idx, prompt: card["text"], correct: correct_by[idx],
        pct: total.positive? ? (correct_by[idx] * 100.0 / total).round : 0 }
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

    # Every responder (answered ≥1 question), not only those who reached Submit —
    # so a respondent compares against all the answers collected per question,
    # matching the creator Results screen. Each row is tallied off its own
    # answers, so partial responses just count toward the questions they reached.
    responses = @survey.responses.where(answered: true)
    render json: { ok: true, total_responses: responses.count,
                   results: aggregate_rows(responses) + token_comparison_rows(responses) }
  end

  # Per-country aggregates for the post-finish map view: one entry per country
  # that has at least one region-tagged responder. Every Verto captures this
  # via the "Where do you live?" demographic question, so there's no separate
  # opt-in gate — an empty result set just renders the "no regional answers
  # yet" copy.
  def regions
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?

    # Every responder (answered ≥1 question), not only completers — consistent
    # with the results comparison above. Only the columns the country grouping
    # + per-country aggregation read, so rows aren't loaded with all their columns.
    tagged = @survey.responses.where(answered: true).where.not(region_country: nil)
                    .select(:id, :region_country, :answers)
    groups = tagged.group_by(&:region_country)
    # Small-cell suppression: a country with fewer than MIN_REGION_SAMPLE_SIZE
    # respondents never appears on the map/list — see Response for why. Two
    # respondents self-declaring different sub-regions of the same country
    # (e.g. "Yorkshire" and "London") count together in one GB group here —
    # display/aggregation is country-level only; region_label stays on the
    # Response row but isn't grouped on.
    rows = groups.filter_map do |country, rs|
      next if rs.size < Response::MIN_REGION_SAMPLE_SIZE
      {
        id:           country,
        country:      country,
        country_name: WorldRegions.name_for(country),
        responders:   rs.size,
        results:      aggregate_rows(rs)
      }
    end.sort_by { |r| -r[:responders] }
    render json: { ok: true, total_tagged: tagged.size, regions: rows }
  end

  # Satnav-style location search backing the welcome-card intake: forwards a
  # partial place name to Nominatim and resolves each hit down to the same
  # coarse country + area shape apply_region already accepts — never a precise
  # address or coordinate (see NominatimClient's privacy note).
  def location_search
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey

    results = NominatimClient.search(query: params[:q].to_s).map do |place|
      label = [ place[:city], place[:region] ].compact_blank.join(", ").first(60).presence
      {
        display_name: place[:display_name],
        country_code: place[:country_code],
        label: label
      }
    end
    render json: { ok: true, results: results }
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    render json: { ok: false, error: "Search failed" }, status: :bad_gateway
  end

  private

  # Swap the inherited :modern version set for the player's own (see
  # PLAYER_BROWSER_VERSIONS). Keeps the caller's `block` so a browser that really
  # is too old still gets the standard 406 page rather than a broken screen.
  def allow_browser(versions:, block:)
    super(versions: PLAYER_BROWSER_VERSIONS, block: block)
  end

  # Finds (or starts) this session's response row and attaches it to the
  # current survey/share — the shared first step of every write action.
  def find_or_init_response(token)
    resp = Response.find_or_initialize_by(session_token: token)
    resp.survey       ||= @survey
    resp.survey_share ||= @survey_share
    resp
  end

  # NB: the status column defaults to "completed", so a freshly initialized
  # record already reads "completed" — only preserve it for rows already saved
  # as completed (e.g. a late progress ping after submit), otherwise mark
  # "started".
  def mark_started_unless_completed(resp)
    resp.status = "started" unless resp.persisted? && resp.status == "completed"
    stamp_started_metadata(resp)
  end

  # The quiz answer feedback in the language the respondent is actually reading,
  # falling back to the source text when this Verto has no translation for it.
  def localized_explanation(card, locale)
    helpers.localized_card(card, locale, @survey.default_locale)["explanation"].to_s
  end

  # First-touch metadata for the response. Both are `||=` on purpose: /progress
  # fires on every card, a refresh reuses the same session_token, and an offline
  # submit can replay hours later — none of which should move the clock back to
  # the start or relabel the device.
  def stamp_started_metadata(resp)
    resp.started_at  ||= Time.current
    resp.device_kind ||= DeviceKind.from(request.user_agent)
  end

  # The answers already persisted for a response (empty for a brand-new row).
  def stored_answers(resp)
    resp.persisted? && resp.answers.is_a?(Hash) ? resp.answers : {}
  end

  # Anti-cheat for quizzes and tokenised Vertos: a graded or token-awarding
  # card that already holds a committed answer is locked — its stored value
  # always wins over anything in the new payload, so a respondent can't go
  # back and change an answer to earn more tokens (or fix a wrong quiz
  # answer). Non-graded, non-awarding (measurement) cards and not-yet-answered
  # cards take the incoming value as normal. A plain Verto (neither quiz nor
  # tokenised) merges nothing (incoming wins outright).
  def locked_merge(stored, incoming)
    incoming = incoming.is_a?(Hash) ? incoming : {}
    return incoming unless @survey.quiz? || @survey.tokenisation_enabled?
    stored = stored.is_a?(Hash) ? stored : {}
    merged = incoming.dup
    Array(@survey.cards).each_with_index do |card, idx|
      next unless QuizGrading.graded?(card) || TokenGrading.awarding?(card)
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

  # Free-text quiz answers rarely match an accepted answer verbatim ("make the
  # laws" vs. the accepted "make laws") — the very first time an open_ended
  # graded card is answered, ask Claude whether a near-miss is a genuine
  # semantic match and, if so, rewrite the stored value to the accepted
  # wording. Every later recomputation of this answer (apply_quiz_score, the
  # scores endpoint, a resave from a chatty client) is then a plain, free
  # exact-match check via QuizGrading — nothing re-asks the AI for the same
  # answer twice. Called from #grade only when the caller has confirmed this
  # card had no committed answer before this request.
  def ai_normalize_open_ended_answer!(resp, idx)
    card = Array(@survey.cards)[idx]
    return unless card && card["type"].to_s == "open_ended" && QuizGrading.graded?(card)

    key   = idx.to_s
    entry = resp.answers[key]
    return unless entry.is_a?(Hash)
    value = entry["value"]
    return if value.to_s.strip.empty?
    return if QuizGrading.correct?(card, value) # already an exact match — nothing to do

    accepted = Array(card["correct"]).map(&:to_s).reject(&:empty?)
    return if accepted.empty?
    return unless QuizAnswerGrader.new.call(question: card["text"].to_s, accepted_answers: accepted, answer: value.to_s)

    # Reassign the whole hash (rather than mutate the nested entry in place)
    # so ActiveRecord's dirty-tracking on the JSON column reliably sees it.
    resp.answers = resp.answers.merge(key => entry.merge("value" => accepted.first))
  rescue => e
    ErrorReporting.report("PlayerController#grade", e)
    # Best-effort: the respondent keeps the exact-match verdict.
  end

  # Cache the server-computed score on quiz responses so "how you compare" is a
  # cheap read; a no-op for non-quiz Vertos.
  def apply_quiz_score(resp)
    return unless @survey.quiz?
    result = QuizGrading.score(@survey.cards, resp.answers)
    resp.score    = result[:score]
    resp.quiz_max = result[:max]
  end

  # Cache the server-computed token totals on tokenised responses, recomputed
  # from the (already locked_merge-protected) stored answers — never trusting
  # anything the client claims its own running total is. A no-op for
  # non-tokenised Vertos.
  def apply_token_totals(resp)
    return unless @survey.tokenisation_enabled?
    resp.token_totals = TokenGrading.totals(@survey.cards, resp.answers, @survey.token_type_ids)
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

  # Tokenisation: one synthetic row per token type, appended after the
  # per-question rows — this is how "compare your tokens" folds into the
  # existing results-comparison panel instead of a separate endpoint/panel.
  # A histogram of each response's cached token_totals[id], the same shape
  # `scores`' score histogram uses.
  def token_comparison_rows(responses)
    return [] unless @survey.tokenisation_enabled?
    token_types = Array(@survey.token_types)
    return [] if token_types.empty?

    dist  = Hash.new { |h, k| h[k] = Hash.new(0) }
    total = 0
    responses.reorder(nil).select(:id, :token_totals).find_each(batch_size: 500) do |r|
      total += 1
      totals = r.token_totals || {}
      token_types.each { |t| dist[t["id"]][totals[t["id"]].to_i] += 1 }
    end

    token_types.map do |t|
      {
        index:    "token:#{t['id']}",
        type:     "token_total",
        token_id: t["id"],
        prompt:   [ t["icon"], t["name"] ].compact_blank.join(" "),
        total:    total,
        counts:   dist[t["id"]]
      }
    end
  end

  # Region data comes from one universal source: the "Where do you live?"
  # demographic question (DemographicQuestions), a location-search card whose
  # answer value is a plain "CC|Label" string — never inferred, never a
  # precise address (see NominatimClient). Must run AFTER resp.answers is set,
  # since it reads the freshly merged answer. An unanswered/invalid pick just
  # leaves the response untagged, same as skipping any other optional card.
  def sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    idx = Array(@survey.cards).find_index { |c| c.is_a?(Hash) && c["demographic"] && c["input"] == "location" }
    value = idx && resp.answers.is_a?(Hash) ? resp.answers[idx.to_s]&.dig("value") : nil
    sep = value.to_s.index("|")
    country = sep ? value[0...sep].to_s.upcase.presence : nil
    label   = sep ? value[(sep + 1)..].to_s.strip.first(60).presence : nil

    if country && WorldRegions.valid?(country)
      resp.region_country = country
      resp.region_label   = label
    else
      resp.region_country = nil
      resp.region_label   = nil
    end
  end

  # Denormalise the two set demographic answers that make useful filter
  # dimensions, for the same reason region is denormalised: the alternative is a
  # JSON query keyed by a card index that differs per Verto.
  #
  # Re-derived on every save rather than written once, so a respondent who goes
  # back and changes their answer is reflected — same as the region above.
  def sync_demographics_from_answers!(resp)
    cards = Array(@survey.cards)
    answers = resp.answers.is_a?(Hash) ? resp.answers : {}

    gender_idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["type"] == "multiple_choice" }
    gender     = gender_idx ? answers[gender_idx.to_s]&.dig("value").to_s.strip.presence : nil
    # Only the options this Verto actually offers, so a tampered payload can't
    # invent a segment label that then renders in the creator's dashboard.
    allowed    = gender_idx ? Array(cards[gender_idx]["options"]).map(&:to_s) : []
    resp.demographic_gender = allowed.include?(gender) ? gender : nil

    birth_idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["input"] == "month" }
    raw_year  = birth_idx ? answers[birth_idx.to_s]&.dig("value").to_s[/\A(\d{4})/, 1] : nil
    year      = raw_year&.to_i
    # A year outside living memory is a typo or a probe, not a birth year.
    resp.demographic_birth_year = year && year.between?(1900, Date.current.year) ? year : nil
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
    else
      # publish_token is the default opaque link; slug is the creator's
      # optional custom/vanity alternative — either resolves the same survey.
      # The slug lookup requires publish_token to be set too, so a slug never
      # makes an unpublished/draft survey reachable — it aliases the same
      # "is this Verto actually published" boundary the token itself enforces.
      @survey = Survey.without_report_text.find_by(publish_token: token) ||
                Survey.without_report_text.where.not(publish_token: nil).find_by(slug: token)
    end
  end
end
