class SurveySummariesController < ApplicationController
  include ActionController::Live
  include AggregatesSurveyResults
  include ResolvesResultSegments
  include LimitsConcurrentStreams
  include ThrottlesAiSpend

  limit_concurrent_streams only: [ :show, :texts ]

  # Deliberately NOT counted against the organisation's daily cap: both actions
  # replay a cached summary when the response count hasn't moved, so most
  # requests here spend nothing and charging them against a spend ceiling would
  # lock creators out of reading text they already paid for. The rate limit
  # still bounds the cold-cache case (P0-4).
  throttle_ai to: 30, within: 1.hour, name: "ai-summary", respond: :plain, only: %i[ show texts ]

  def show
    survey    = Current.organisation.surveys.find(params[:id])
    responses = survey.responses.where(status: "completed").order(created_at: :desc)
    total     = responses.count

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    if survey.results_summary.present? && survey.results_summary_response_count == total
      response.stream.write(survey.results_summary)
      return
    end

    aggregated = aggregate_results(Array(survey.cards), responses)
    full_text  = +""

    ResultsSummariser.new.call(survey: survey, aggregated: aggregated, total: total) do |chunk|
      response.stream.write(chunk)
      full_text << chunk
    end

    survey.update_columns(
      results_summary:                full_text,
      results_summary_response_count: total
    ) if full_text.present?
  rescue ActiveRecord::RecordNotFound
    raise # let Rails return a clean 404 before any stream is opened
  rescue => e
    ErrorReporting.report("SurveySummariesController", e)
    response.stream.write("Insights unavailable.") rescue nil
  ensure
    response.stream.close if response.committed?
  end

  # GET /surveys/:id/results/summarize_texts?card_index=&segment=
  # Streams a short AI theme summary of one open-ended question's free-text
  # answers, scoped to a single results segment (a region, a partner share, or
  # "overall") — the per-region qualitative digest surfaced in the Compare
  # view (results_compare_controller.js), where reading every raw answer
  # segment-by-segment doesn't scale. Not cached: segment-scoped requests are
  # comparatively rare (an explicit click per card+segment), unlike the
  # whole-survey summary above which every results-page visit would trigger.
  def texts
    survey = Current.organisation.surveys.find(params[:id])
    cards  = Array(survey.cards)
    idx    = params[:card_index].to_i
    card   = cards[idx]

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    # The demographic tail (birth month, location) is open_ended too, but its
    # values are structured picks ("GB|London", "1995-06"), not qualitative
    # text worth theme-summarising — see DemographicQuestions.
    unless card.is_a?(Hash) && card["type"] == "open_ended" && card["demographic"].blank?
      response.stream.write("Not an open-text question.")
      return
    end

    _base, segments, = resolve_result_segments(survey, nil)
    segment = segments.find { |s| s[:id] == params[:segment] }
    unless segment
      response.stream.write("Unknown segment.")
      return
    end

    # Aggregate the FULL card list (not just this one) so each response's
    # answers hash — keyed by the card's real position in survey.cards — lines
    # up correctly; aggregate_results indexes positionally against whatever
    # array it's given, so trimming to [card] alone would silently read every
    # response's answer at index 0 instead of this card's actual index.
    texts = aggregate_results(cards, segment[:scope])[idx][:texts]

    OpenTextSummariser.new.call(question: card["text"], texts: texts) do |chunk|
      response.stream.write(chunk)
    end
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    ErrorReporting.report("SurveySummariesController#texts", e)
    response.stream.write("Summary unavailable.") rescue nil
  ensure
    response.stream.close if response.committed?
  end
end
