# frozen_string_literal: true

# Bounds how long a request may hold one of Puma's three threads.
#
# Production runs a single Ruby process with three request threads
# (config/puma.rb), so three wedged requests take the whole app down. Nothing
# bounded request duration before this: single-mode Puma ignores
# `worker_timeout`, and the only real ceiling was per-Claude-call
# (ANTHROPIC_TIMEOUT_SECONDS, 120s with one retry) — which several endpoints
# multiply by the number of cards or locales.
#
# rack-timeout is the mechanism, but it has no per-path setting: one instance
# means one bound for the entire app. That doesn't fit here, because the spread
# between a dashboard render and a multi-locale flow generation is two orders of
# magnitude. So we build one Rack::Timeout per tier and pick between them per
# request:
#
#   :skip    — the streaming endpoints. They hold a thread for as long as Claude
#              keeps writing *by design* (see LimitsConcurrentStreams), are
#              already capped to one concurrent by the slot pool, and time out
#              by Thread#raise — which mid-stream truncates a response the
#              client cannot distinguish from a complete one.
#   :slow    — the AI editor endpoints, the imports and the exports. Minutes are
#              legitimate here. The Google API clients have no timeout of their
#              own, so for those this is the only bound there is.
#   :default — everything else.
#
# Tiers are keyed off *named routes*, not hand-written path strings: a renamed
# or moved route raises at boot rather than silently losing its carve-out.
module RequestTimeout
  # Streaming responses — no bound at all. See the note on :skip above.
  SKIP_ROUTES = %i[
    survey_results_summary
    survey_results_summarize_texts
    survey_results_report_stream
    survey_chat
    ask_thread_messages
  ].freeze

  # Claude calls, imports and exports: slow on purpose, but not unbounded.
  SLOW_ROUTES = %i[
    generate_survey
    generate_survey_card
    generate_survey_flow
    optimise_survey_card
    moderate_image_survey
    create_blank_survey
    shuffle_survey_assets
    import_pdf_survey
    import_google_form_survey
    import_manual_survey
    resume_import
    finalize_import_survey
    survey_template
    survey_results_report
    survey_results_export
    survey_google_sheet
    survey_google_drive
    download_report_render
  ].freeze

  # Deliberately not tighter to start with: CommonQuestionAggregator still loads
  # every response with all columns, so a large account's dashboard is the one
  # ordinary page that could plausibly run long. Tighten on evidence, rather
  # than discovering the floor as an outage.
  DEFAULT_SECONDS = 45
  SLOW_SECONDS    = 240

  class << self
    def default_seconds
      seconds_from_env("REQUEST_TIMEOUT_DEFAULT", DEFAULT_SECONDS)
    end

    def slow_seconds
      seconds_from_env("REQUEST_TIMEOUT_SLOW", SLOW_SECONDS)
    end

    # Production only by default, matching how the memory watchdog and the
    # stream bulkhead are gated, with an env opt-in so it can be exercised
    # deliberately elsewhere.
    def enabled?
      return ENV["REQUEST_TIMEOUT_ENABLED"] == "true" if ENV.key?("REQUEST_TIMEOUT_ENABLED")

      Rails.env.production?
    end

    def tier_for(method, path)
      return :skip if matched?(skip_matchers, method, path)
      return :slow if matched?(slow_matchers, method, path)

      :default
    end

    def seconds_for(method, path)
      case tier_for(method, path)
      when :skip then nil
      when :slow then slow_seconds
      else            default_seconds
      end
    end

    def skip_matchers
      @skip_matchers ||= matchers_for(SKIP_ROUTES)
    end

    def slow_matchers
      @slow_matchers ||= matchers_for(SLOW_ROUTES)
    end

    # Matchers are memoized off the route set; tests that reload routes need to
    # drop them.
    def reset!
      @skip_matchers = nil
      @slow_matchers = nil
    end

    private

      def seconds_from_env(key, fallback)
        raw = ENV[key]
        return fallback if raw.blank?

        Integer(raw)
      rescue ArgumentError
        fallback
      end

      def matched?(matchers, method, path)
        matchers.any? { |verb, pattern| verb == method && pattern.match?(path) }
      end

      def matchers_for(names)
        # Routes load lazily in Rails 8 — named_routes is empty until forced.
        Rails.application.reload_routes_unless_loaded
        names.map { |name| matcher_for(name) }
      end

      def matcher_for(name)
        route = Rails.application.routes.named_routes.get(name)
        if route.nil?
          raise ArgumentError,
                "RequestTimeout: no route named #{name.inspect}. A route was renamed or " \
                "removed — update SKIP_ROUTES/SLOW_ROUTES in lib/request_timeout.rb so the " \
                "endpoint keeps its timeout tier."
        end

        [ route.verb, path_pattern(route) ]
      end

      # "/surveys/:id/generate_flow(.:format)" -> %r{\A/surveys/[^/]+/generate_flow(?:\.\w+)?\z}
      def path_pattern(route)
        spec = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
        body = spec.split("/").map { |segment|
          segment.start_with?(":") ? "[^/]+" : Regexp.escape(segment)
        }.join("/")

        /\A#{body}(?:\.\w+)?\z/
      end
  end

  # Picks a Rack::Timeout instance per request. Composing instances keeps us on
  # the gem's public constructor, so this can't break on a gem upgrade.
  class Middleware
    def initialize(app)
      @app = app
      @default = build(app, RequestTimeout.default_seconds)
      @slow    = build(app, RequestTimeout.slow_seconds)
    end

    def call(env)
      case RequestTimeout.tier_for(env["REQUEST_METHOD"], env["PATH_INFO"])
      when :skip then @app.call(env)
      when :slow then @slow.call(env)
      else            @default.call(env)
      end
    end

    private

      def build(app, seconds)
        # wait_timeout is off by default, deliberately. It only engages when
        # the proxy sets X-Request-Start, but when it does, rack-timeout
        # *reduces* the service timeout to whatever is left of the wait budget
        # (service_past_wait defaults to false) — which would silently clamp
        # the slow tier's four minutes down to well under one. Off,
        # service_timeout means exactly what it says on every tier.
        #
        # REQUEST_WAIT_TIMEOUT (seconds) opts into request SHEDDING for a
        # high-load window: under saturation, clients abandon at their own
        # timeouts (the player's service worker gives up on HTML at 3.5s)
        # while Puma keeps dequeuing and fully serving those dead requests —
        # goodput collapses to zero at 100% busy. With a wait budget, a
        # request that already sat in the queue longer than the client would
        # wait is dropped on arrival instead of served into the void.
        # service_past_wait: true keeps each tier's service_timeout intact
        # (shed stale requests, never clamp live ones). Only meaningful when
        # the fronting proxy stamps X-Request-Start — verify that on the
        # scratch environment before relying on it for an event.
        wait = ENV["REQUEST_WAIT_TIMEOUT"].to_i
        if wait.positive?
          Rack::Timeout.new(app, service_timeout: seconds,
                                 wait_timeout: wait, service_past_wait: true)
        else
          Rack::Timeout.new(app, service_timeout: seconds, wait_timeout: false)
        end
      end
  end
end
