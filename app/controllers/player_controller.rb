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
  rate_limit to: 120, within: 1.minute, only: [ :results, :scores, :regions, :leaderboard ],
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  # Consent is written at most twice per legitimate session (a decline, or a
  # decline followed by an explicit re-agree), and declining PURGES the
  # response — so an uncapped endpoint was an unauthenticated, repeatable
  # destruction primitive keyed only by a session token.
  rate_limit to: 30, within: 1.minute, only: :consent,
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  # A respondent's autocomplete keystrokes are debounced client-side, so a
  # generous per-minute cap here only guards against a runaway client/bot.
  rate_limit to: 30, within: 1.minute, only: :location_search,
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }

  # How many respondent-facing Claude calls may be in flight in this process.
  # Rate limiting above bounds requests per IP; this bounds concurrency, which
  # is the thing that actually exhausts a 3-thread pool — and it has to, because
  # respondents behind one venue's NAT are legitimate traffic the caps let past.
  #
  # A separate pool from LimitsConcurrentStreams::POOL by design: that one is
  # sized for creator report streams, and sharing it would let a creator
  # watching a report write itself turn away a respondent mid-quiz, or the
  # reverse. Same formula (leave two threads for ordinary requests), tunable on
  # its own so respondent and creator AI can be balanced independently.
  AI_GRADE_POOL = SlotPool.new(
    [ (ENV["AI_GRADE_SLOTS"].presence&.to_i || (Integer(ENV.fetch("RAILS_MAX_THREADS", 3)) - 2)), 1 ].max
  )

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

  # A Verto is meant to be embedded — in a partner's page, in a one-pager sent
  # as an HTML file (public/vertonow.html). The app-wide policy's
  # `frame-ancestors 'self'` blocks both, and 'self' is the only reason the
  # one-pager's laptop mockup couldn't hold the real thing.
  #
  # `file:` is what makes a downloaded copy work: a local page's origin is
  # opaque, and Chrome matches it against neither 'self' nor even `*` — only a
  # `file:` scheme source. Deliberately NOT `*`: this grants the app's own
  # origin and locally-opened files, so no website gains the ability to frame a
  # Verto. X-Frame-Options has to go with it, since Rails' default SAMEORIGIN
  # would block a file:// parent on its own whatever the CSP says.
  #
  # Set as a plain response header rather than through the
  # `content_security_policy` macro — see config/initializers/blazer.rb: that
  # macro shallow-clones and mutates the shared global policy, leaking the
  # relaxation into every other response in the process.
  after_action :allow_embedding, only: %i[ show test_show ]

  before_action :load_survey_and_share, except: :test_show
  # A tester opening a shared link is read-only traffic; aligned with the
  # other public read endpoints above.
  rate_limit to: 120, within: 1.minute, only: :test_show

  # GET /test/:token — Test Mode. The exact respondent experience (drafts
  # included) with every recording endpoint blanked, shareable without
  # sign-in. Reuses the owner-preview machinery in player/show.html.erb:
  # @preview blanks progress/submit/consent, and @test_mode additionally
  # blanks the play token itself so no results/regions/quiz URL leaks a live
  # endpoint to an unauthenticated tester.
  def test_show
    @survey = Survey.without_report_text.find_by(test_token: params[:token])
    return render :unavailable, status: :not_found unless @survey
    if @survey.deleted?
      @oops_gone = true
      return render :unavailable, status: :gone
    end
    @preview   = true
    @test_mode = true
    @display_locale = resolve_play_locale
    render_with_chrome_language
  end

  def show
    # A token that resolves nothing is almost always a link shared before the
    # Verto was published (or a typo) — a respondent dead-end either way, so
    # serve a branded explainer instead of a bare error string.
    return render :unavailable, status: :not_found unless @survey
    if @survey.deleted?
      @oops_gone = true
      return render :unavailable, status: :gone
    end
    # Unpublished by the creator. The link itself is real and may well come back
    # (unpublishing keeps publish_token so re-publishing restores it), so this is
    # a 410 rather than a 404 — but the "not published yet" copy is the accurate
    # explanation for a respondent, not the archived-forever one.
    return render :unavailable, status: :gone unless @survey.published?
    @display_locale = resolve_play_locale
    render_with_chrome_language
  end

  # Partial save while the player is mid-survey, so we can count people who
  # answered at least one question even if they never reach Submit. Idempotent
  # per session_token (a refresh reuses the token) and never downgrades a
  # response that has already been completed.
  def progress
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = find_or_init_response(token)
    return if refuse_if_declined(resp)
    # Quiz answers are immutable once committed — fold the incoming payload over
    # what's already stored so an already-answered graded card can't be changed.
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    apply_respondent_code(resp, data["respondent_code"])
    apply_player_key(resp, data["player_key"])
    sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    mark_started_unless_completed(resp)
    apply_quiz_score(resp)
    apply_token_totals(resp)
    resp.save!
    render json: { ok: true, session_token: token }
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    # 500, not 422: a transient fault (DB burp, mid-deploy restart) must look
    # RETRYABLE to the service worker, which queues 5xx and drops 4xx. As a 422
    # this told the respondent the Verto had closed and threw their answers
    # away, when a retry seconds later would have landed them.
    render json: { ok: false, error: "Something went wrong saving your response." }, status: :internal_server_error
  end

  def submit
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = find_or_init_response(token)
    return if refuse_if_declined(resp)
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    apply_respondent_code(resp, data["respondent_code"])
    apply_player_key(resp, data["player_key"])
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
    # Best-effort: have the finisher's anonymous name minted before the thank-you
    # screen fetches the board. A naming hiccup must never fail the write that
    # just stored the answers — #leaderboard's backfill names anyone missed.
    if @survey.leaderboard_active? && resp.player_key_digest.present?
      begin
        PlayerAlias.ensure_for!(survey: @survey, key_digest: resp.player_key_digest)
      rescue => e
        ErrorReporting.report("PlayerController#submit alias", e)
      end
    end
    payload = { ok: true }
    payload.merge!(score: resp.score, max: resp.quiz_max) if @survey.quiz?
    payload.merge!(token_totals: resp.token_totals) if @survey.tokenisation_enabled?
    render json: payload
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    # 500, not 422: a transient fault (DB burp, mid-deploy restart) must look
    # RETRYABLE to the service worker, which queues 5xx and drops 4xx. As a 422
    # this told the respondent the Verto had closed and threw their answers
    # away, when a retry seconds later would have landed them.
    render json: { ok: false, error: "Something went wrong saving your response." }, status: :internal_server_error
  end

  # Records the consent gate's agree/decline event, so there's an audit trail
  # of who consented and to what wording — previously agreeConsent()/
  # declineConsent() were pure client-side UI with nothing persisted. The
  # first event for a session wins (a retry/replay never overwrites an
  # already-recorded timestamp), and the snapshot ties the record to the exact
  # consent_text shown at that moment, immune to the creator editing it later.
  def consent
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?

    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = find_or_init_response(token)
    mark_started_unless_completed(resp)
    if data["agreed"]
      resp.consent_agreed_at ||= Time.current
      resp.consent_text_snapshot ||= @survey.consent_snapshot_text
      # An explicit agree after a decline is a re-consent, and the record must
      # say ONE thing — both timestamps standing at once is an audit row nobody
      # can interpret. The purge already ran; nothing is resurrected by this.
      resp.consent_declined_at = nil
    else
      resp.consent_declined_at ||= Time.current
      resp.consent_text_snapshot ||= @survey.consent_snapshot_text
      # Declining means "do not collect my data" — so anything already collected
      # goes. Before this it was a timestamp and nothing more: answers given
      # before a mid-deck gate stayed stored, counted as a responder, and fed
      # the creator's and the public aggregates.
      resp.purge_for_declined_consent!
    end
    resp.save!
    render json: { ok: true }
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
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
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    return render json: { ok: false, error: "Not a quiz" }, status: :forbidden unless @survey.quiz?

    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    idx   = data["card_index"].to_i
    resp  = find_or_init_response(token)
    return if refuse_if_declined(resp)
    first_time = !answered?(stored_answers(resp)[idx.to_s])
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    apply_player_key(resp, data["player_key"])
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
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    render json: { ok: false, error: "Something went wrong scoring your answer." }, status: :unprocessable_entity
  end

  # Quiz: the session's already-committed graded cards, so a reload re-locks and
  # re-reveals them (refresh-proof no-redo). Resolved by the client's session
  # token; these answers are already committed, so revealing them is safe.
  def quiz_state
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
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
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    return render json: { ok: false, error: "Not a quiz" }, status: :forbidden unless @survey.quiz?

    max    = QuizGrading.graded_indices(@survey.cards).size
    graded = Array(@survey.cards).each_with_index.select { |card, _idx| QuizGrading.graded?(card) }

    # Small-cell suppression (P1-14), as on #results. A per-question
    # correct-rate over one other person is that person's answer sheet: "100%
    # got Q3 right" with a total of 1 says exactly what they scored.
    scored = @survey.responses.where(status: "completed").where.not(score: nil)
    if scored.count < Response::MIN_REGION_SAMPLE_SIZE
      return render json: { ok: true, suppressed: true, total: scored.count, max: max,
                            average: 0.0, distribution: [], per_question: [] }
    end

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

  # How many standings rows the board shows. "You" rides along even from
  # further down, with your true rank.
  LEADERBOARD_TOP = 10

  # The token leaderboard: identities ranked under the creator's retake policy,
  # wearing their system-made anonymous names. Enablement is enforced here, not
  # just by hiding the CTA (the #results posture), and the whole payload is
  # anonymous by construction — names and totals, no answers, no identities.
  def leaderboard
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    unless @survey.leaderboard_active?
      return render json: { ok: false, error: "Leaderboard not enabled" }, status: :forbidden
    end

    standings = TokenLeaderboard.standings(@survey)

    # Resolve "you": the saved row's digest once this session has written, else
    # the raw key the client sent — a recognised returner opening a fresh
    # session (no_redo's straight-to-board path) has a key but no row yet.
    token = params[:session_token].to_s
    resp  = token.present? ? @survey.responses.find_by(session_token: token) : nil
    you_digest = resp&.player_key_digest.presence || @survey.player_key_digest(params[:player_key])
    you_index  = you_digest ? standings.index { |e| e[:key_digest] == you_digest } : nil

    # Read-time backfill: name everyone about to be rendered (≤11 idempotent
    # finds). Submit already minted most of them; this covers identities from
    # before a mid-flight enable, and seeded rows.
    top = standings.first(LEADERBOARD_TOP)
    shown = top.map { |e| e[:key_digest] }
    shown |= [ you_digest ] if you_index
    shown.each { |digest| PlayerAlias.ensure_for!(survey: @survey, key_digest: digest) }
    names = @survey.player_aliases.where(key_digest: shown).pluck(:key_digest, :anon_name).to_h

    entries = top.each_with_index.map do |e, i|
      { rank: i + 1, name: names[e[:key_digest]], total: e[:total], you: e[:key_digest] == you_digest }
    end
    you = if you_index
      { rank: you_index + 1, name: names[you_digest],
        total: standings[you_index][:total], of: standings.size }
    end
    render json: { ok: true, policy: @survey.leaderboard_retake_policy,
                   total_players: standings.size, entries:, you: }
  end

  def results
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    # The link decides, not just the Verto — otherwise a cohort sent a
    # comparison-off link could still read the aggregate straight off this
    # endpoint, which is the exact thing turning it off was meant to prevent.
    unless play_settings.compare_results?
      return render json: { ok: false, error: "Comparison not enabled" }, status: :forbidden
    end

    # Every responder (answered ≥1 question), not only those who reached Submit —
    # so a respondent compares against all the answers collected per question,
    # matching the creator Results screen. Each row is tallied off its own
    # answers, so partial responses just count toward the questions they reached.
    responses = @survey.responses.where(answered: true)
    total     = responses.count

    # Small-cell suppression (P1-14). #regions has enforced this from the start;
    # #results did not, so on a Verto with one or two responders the comparison
    # a respondent is shown IS the other respondent's answers, attributable to
    # them by anyone who knows who else was asked. Same threshold and same
    # reasoning as the map — see Response::MIN_REGION_SAMPLE_SIZE.
    if total < Response::MIN_REGION_SAMPLE_SIZE
      return render json: { ok: true, suppressed: true, total_responses: total, results: [] }
    end

    render json: { ok: true, total_responses: total,
                   results: aggregate_rows(responses) + token_comparison_rows(responses) }
  end

  # Per-country aggregates for the post-finish map view: one entry per country
  # that has at least one region-tagged responder. Every Verto captures this
  # via the "Where do you live?" demographic question, so there's no separate
  # opt-in gate — an empty result set just renders the "no regional answers
  # yet" copy.
  def regions
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    # Mirrors the #results guard above: hiding the CTA isn't enough, the endpoint
    # is public and answers anyone who asks.
    unless @survey.regions_enabled?
      return render json: { ok: false, error: "Regional comparison not enabled" }, status: :forbidden
    end

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
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    render json: { ok: false, error: "Search failed" }, status: :bad_gateway
  end

  private

  # See the after_action above. Overrides frame-ancestors for THIS request only,
  # leaving every other directive of the app-wide policy (script-src, img-src,
  # the Pexels hosts…) exactly as configured.
  #
  # Done by handing the middleware a per-request policy rather than writing the
  # header here: the CSP middleware builds the header on the way out, AFTER this
  # runs, and skips a header that's already set — so writing one directly would
  # have replaced the player's whole policy with this single directive. A dup,
  # not the global object, so the relaxation can't leak into other responses
  # (the hazard config/initializers/blazer.rb documents).
  def allow_embedding
    policy = request.content_security_policy
    return if policy.nil?

    embeddable = policy.dup
    embeddable.frame_ancestors :self, "file:"
    request.content_security_policy = embeddable

    # Rails' default SAMEORIGIN blocks a file:// parent on its own, whatever the
    # CSP says — modern browsers prefer frame-ancestors, but only when
    # X-Frame-Options isn't there to contradict it.
    response.headers.delete("X-Frame-Options")
  end

  # Swap the inherited :modern version set for the player's own (see
  # PLAYER_BROWSER_VERSIONS). Keeps the caller's `block` so a browser that really
  # is too old still gets the standard 406 page rather than a broken screen.
  def allow_browser(versions:, block:)
    super(versions: PLAYER_BROWSER_VERSIONS, block: block)
  end

  # Finds (or starts) this session's response row and attaches it to the
  # current survey/share — the shared first step of every write action.
  # A token that belongs to a different survey is refused, not adopted.
  class CrossSurveyToken < StandardError; end

  def find_or_init_response(token)
    resp = @survey.responses.find_or_initialize_by(session_token: token)
    if resp.new_record? && Response.where(session_token: token).where.not(survey_id: @survey.id).exists?
      # The old global lookup made any playable survey's consent URL a lever on
      # ANOTHER survey's response — including the purge. The client's tokens
      # are keyed per Verto (sessionStorage key includes the submit URL), so a
      # legitimate respondent never hits this; only a crafted request can.
      raise CrossSurveyToken
    end
    resp.survey_share ||= @survey_share
    # Which named share link this respondent came in on, so the Share panel can
    # say what each audience actually returned. Set once, like the share.
    resp.survey_link ||= @survey_link
    # Wave 1 is implicit (current_wave is nil until start_next_wave! is first
    # called), so this is a no-op until then — exactly the "nil means wave 1"
    # contract Survey#waved? relies on.
    resp.survey_wave_id ||= @survey.current_wave&.id
    resp
  end

  # Declining consent is terminal until the respondent explicitly re-agrees.
  # Without this the purge only held for an instant: any later /progress,
  # /submit or /grade with the same token — an in-flight request, a queued
  # replay, a crafted POST — re-stored everything and re-entered the respondent
  # in every count, while the row still said they had declined.
  def refuse_if_declined(resp)
    return false unless resp.persisted? && resp.consent_declined_at.present?
    render json: { ok: false, error: "Consent was declined for this session." }, status: :forbidden
    true
  end

  # Record the respondent's self-invented code as a digest. The plaintext is used
  # to compute the HMAC and then dropped on the floor — it is never assigned to
  # the record, never logged (see filter_parameter_logging) and never returned.
  #
  # Set once per response: a later request can't overwrite it, so a respondent who
  # reloads mid-Verto keeps the identity they started with.
  def apply_respondent_code(resp, code)
    return unless @survey.respondent_code_enabled?
    return if resp.respondent_code_digest.present?

    digest = @survey.respondent_code_digest(code)
    resp.respondent_code_digest = digest if digest
  end

  # The leaderboard identity, same discipline as the respondent code above:
  # recorded only while the feature is on, only as a digest, and set once per
  # response — a reload keeps the identity it started with.
  def apply_player_key(resp, key)
    return unless @survey.leaderboard_active?
    return if resp.player_key_digest.present?

    digest = @survey.player_key_digest(key)
    resp.player_key_digest = digest if digest
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
    # Every write path goes through here, so it's the one place free text has to
    # be bounded — the client's maxlength is a courtesy, and this endpoint is
    # public and takes JSON.
    incoming = @survey.clamp_free_text(incoming.is_a?(Hash) ? incoming : {})
    incoming = @survey.clamp_contact_entries(incoming)
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
  # One definition, in Response — this was a third implementation of it, and it
  # disagreed with both of the others. See Response.answered_entry? for what the
  # rule is and why each clause is there. locked_merge uses it to decide what a
  # later submit may not overwrite.
  def answered?(ans)
    Response.answered_entry?(ans)
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
    return unless ai_confirms_match?(question: card["text"].to_s, accepted_answers: accepted, answer: value.to_s)

    # Reassign the whole hash (rather than mutate the nested entry in place)
    # so ActiveRecord's dirty-tracking on the JSON column reliably sees it.
    resp.answers = resp.answers.merge(key => entry.merge("value" => accepted.first))
  rescue => e
    ErrorReporting.report("PlayerController#grade", e)
    # Best-effort: the respondent keeps the exact-match verdict.
  end

  # Ask Claude whether a near-miss answer is a genuine match — but only if this
  # process has a slot free for respondent-facing AI.
  #
  # #grade is public and unauthenticated, so this is the one Claude call a
  # creator cannot throttle: a popular quiz with open-ended graded cards can
  # point real respondent traffic straight at it, and three Puma threads is all
  # there is. When every slot is busy we skip the call and the respondent keeps
  # the exact-match verdict — the exact outcome the rescue above has always
  # produced on a network error, so this adds no new behaviour, only a bound.
  #
  # The bound sits here rather than around the action on purpose: #grade saves
  # the respondent's answer *after* this step, so short-circuiting the action
  # would drop the answer itself, not just the refinement.
  def ai_confirms_match?(question:, accepted_answers:, answer:)
    AI_GRADE_POOL.with_slot(false) do
      QuizAnswerGrader.new.call(question: question, accepted_answers: accepted_answers, answer: answer)
    end
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
        avg:    row[:avg],
        # A tap card's counts are keyed by response key; the bars need the words
        # and the order that go with them, and the client has no other way to
        # learn a scale the creator wrote. Key + label only — the colours are
        # already on the card the respondent just answered.
        responses: (TapScales.for_card(row[:card]).map { |r| r.slice("key", "label") } if row[:type] == "tap_card")
      }.compact
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
    # Everything after the first "|" used to be the WHOLE label — now it may
    # itself carry a second "|POSTCODE" segment (capture_postcode). Parsed
    # from `rest`, not the raw value, so a legacy two-segment "CC|Label"
    # answer (no second pipe) still resolves exactly as it always did: sep2
    # is nil, postcode stays nil, label is `rest` unchanged.
    rest    = sep ? value[(sep + 1)..].to_s : nil
    sep2    = rest&.index("|")
    label   = rest ? (sep2 ? rest[0...sep2] : rest).strip.first(60).presence : nil
    postcode = rest && sep2 ? rest[(sep2 + 1)..] : nil

    if country && WorldRegions.valid?(country)
      resp.region_country  = country
      resp.region_label    = label
      # Re-derived from the toggle's CURRENT state, same as every other
      # region field here — a respondent who answered while the toggle was on
      # loses the postcode from this denormalised column if a creator somehow
      # turns it off again (SETTINGS_LOCKED_IN_USE makes that rare, not
      # impossible — a duplicated draft, for instance), matching how turning
      # regions off entirely already blanks region_country/region_label.
      resp.region_postcode = @survey.capture_postcode? ? sanitize_postcode(postcode) : nil
    else
      resp.region_country  = nil
      resp.region_label    = nil
      resp.region_postcode = nil
    end
  end

  # Upcased, bounded, and stripped to a conservative charset — letters,
  # digits, spaces and hyphens cover UK/US/CA/AU-style postcodes without
  # opening the door to anything that could carry markup or break a CSV
  # export. Untrusted input either way: the client packs whatever the
  # respondent typed into the hidden field verbatim.
  POSTCODE_CHARS = /[^A-Z0-9 \-]/
  def sanitize_postcode(raw)
    raw.to_s.strip.upcase.gsub(POSTCODE_CHARS, "").first(10).presence
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

    # The tail's Gender card predates demographic_key, so it is the demographic
    # multiple_choice with NO key (or, future-proofing, key "gender") — the
    # guard is what lets the opt-in Heritage card (also a demographic
    # multiple_choice, key "heritage") coexist without stealing this slot.
    gender_idx = cards.find_index do |c|
      next false unless c.is_a?(Hash) && c["demographic"] && c["type"] == "multiple_choice"
      key = c["demographic_key"].to_s
      key.empty? || key == "gender"
    end
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

    # Opt-in demographics (DemographicQuestions::OPTIONAL_CARDS), same
    # tamper-guard posture: values must be options the card actually offers.
    #
    # Neither card has an "Another…" button any more — someone the list misses
    # types it into the Other box instead. That answer arrives as
    # { value: nil, other: "..." }, so without the second branch below it would
    # denormalise to nothing and exactly the people the list failed would vanish
    # from the segments, which is the opposite of what removing the dead end
    # was for.
    #
    # What gets STORED is the registry's own off-list label, never the typed
    # text: a respondent-authored string in this column renders straight into
    # the creator's dashboard as a segment pill, which is what the allowlist
    # above exists to prevent. The words themselves stay on the answer and reach
    # the creator through the card's own free-text panel and the exports.
    #
    # Guarded on the card's own allow_other, so a decks inserted before the box
    # existed — 9 options, no box — treat a typed payload as the tampering it is.
    heritage_idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["demographic_key"] == "heritage" }
    heritage     = heritage_idx ? answers[heritage_idx.to_s]&.dig("value").to_s.strip.presence : nil
    h_other      = heritage_idx ? answers[heritage_idx.to_s]&.dig("other").to_s.strip.presence : nil
    h_allowed    = heritage_idx ? Array(cards[heritage_idx]["options"]).map(&:to_s) : []
    resp.demographic_heritage =
      if h_allowed.include?(heritage)
        heritage
      elsif h_other && cards[heritage_idx]["allow_other"]
        DemographicQuestions.off_list_label("heritage", locale: @survey.default_locale)
      end

    # Neurodiversity is a multi-select; packed pipe-wrapped and sorted (see
    # the column migration). A label containing "|" would corrupt the packing
    # (only a creator-edited option could — registry labels never do), so it
    # is dropped. Exclusivity: real conditions beat "None of these"/"Prefer
    # not to say" if both were ticked; among exclusives alone, first wins.
    neuro_idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["demographic_key"] == "neurodiversity" }
    picked    = neuro_idx ? Array(answers[neuro_idx.to_s]&.dig("value")).map { |v| v.to_s.strip } : []
    n_other   = neuro_idx ? answers[neuro_idx.to_s]&.dig("other").to_s.strip.presence : nil
    n_allowed = neuro_idx ? Array(cards[neuro_idx]["options"]).map(&:to_s) : []
    valid      = (picked & n_allowed).reject { |v| v.include?("|") }
    conditions = valid.reject { |v| DemographicQuestions.neuro_exclusive_labels.include?(v) }
    # Same off-list handling as heritage. The Other box is a standalone answer
    # platform-wide — typing replaces the ticks — so `picked` is empty whenever
    # `other` is set, and this can't collide with a real selection. A typed
    # answer is a real condition, so it beats the exclusives for the same
    # reason a ticked one does.
    chosen =
      if conditions.any?
        conditions
      elsif n_other && cards[neuro_idx]["allow_other"]
        [ DemographicQuestions.off_list_label("neurodiversity", locale: @survey.default_locale) ]
      else
        valid.first(1)
      end
    resp.demographic_neurodiversity = chosen.compact.any? ? "|#{chosen.compact.sort.join('|')}|" : nil
  end

  # The Verto content language to render: an explicit ?lang=, else the
  # respondent's UI locale if the Verto has it, else the Verto's primary.
  def resolve_play_locale
    @survey.display_locale_for(params[:lang], Current.locale)
  end

  # ApplicationController#switch_locale already wraps this whole request in
  # Current.locale (the visitor's platform locale) — that's why the player's
  # chrome (Back/Next/Submit, consent gate, the required hint, the thank-you
  # screen) has always followed the VISITOR, while card content follows the
  # VERTO (resolve_play_locale). chrome_follows_verto_language nests a second,
  # narrower override around just this render: t() calls made while rendering
  # (which includes the layout, so <html lang/dir> and window.I18N move too)
  # read @display_locale instead, for this response only. Falls back to
  # English chrome for a Verto locale with no chrome translations, via the
  # ordinary i18n fallback chain (config.i18n.fallbacks) — never a raw key.
  def render_with_chrome_language
    if @survey.chrome_follows_verto_language?
      I18n.with_locale(@display_locale) { render :show }
    else
      render :show
    end
  end

  def load_survey_and_share
    token = params[:token]
    # without_report_text: the player never reads the large AI summary/report
    # columns, so skip loading them into the row on every public play request.
    if (share = SurveyShare.find_by(share_token: token))
      @survey_share = share
      @survey = Survey.without_report_text.find_by(id: share.survey_id)
    elsif (link = SurveyLink.active.find_by(slug: token))
      # A named share link. Only active ones resolve, so pausing a link takes it
      # off /play for its reads AND its writes in one step — a page loaded
      # before the pause can't keep posting answers through it.
      @survey_link = link
      @survey = Survey.without_report_text.find_by(id: link.survey_id)
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
