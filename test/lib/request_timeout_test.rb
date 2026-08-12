require "test_helper"
require Rails.root.join("lib/request_timeout")

# An actual timeout is slow and racy to assert, and functional tests bypass the
# middleware stack entirely — so what's tested here is the classifier, plus the
# two boot-time facts that would silently undo it.
class RequestTimeoutTest < ActiveSupport::TestCase
  setup do
    # Routes load lazily in Rails 8; force them so assertions don't depend on
    # whichever test happened to run first.
    Rails.application.reload_routes_unless_loaded
    RequestTimeout.reset!
  end

  teardown { RequestTimeout.reset! }

  # The guard that matters: the tiers are declared as route *names*, so this
  # walks the real route set and fails the moment one is renamed or removed.
  test "every declared route name still exists" do
    (RequestTimeout::SKIP_ROUTES + RequestTimeout::SLOW_ROUTES).each do |name|
      assert_not_nil Rails.application.routes.named_routes.get(name),
                     "no route named #{name.inspect} — its timeout tier has been silently lost"
    end
  end

  test "an unknown route name raises rather than being ignored" do
    error = assert_raises(ArgumentError) do
      RequestTimeout.send(:matchers_for, [ :definitely_not_a_route ])
    end
    assert_match(/no route named/, error.message)
  end

  test "streaming endpoints are never bounded" do
    RequestTimeout::SKIP_ROUTES.each do |name|
      verb, path = example_request_for(name)
      assert_equal :skip, RequestTimeout.tier_for(verb, path),
                   "#{name} (#{verb} #{path}) must stay unbounded — a mid-stream " \
                   "Thread#raise truncates the response invisibly"
      assert_nil RequestTimeout.seconds_for(verb, path)
    end
  end

  # Pinned by path, not by iterating SKIP_ROUTES: removing the symbol from the
  # list must fail here rather than silently dropping the endpoint to 45s. Ask
  # Verto runs its whole tool-round phase before the first stream write, so the
  # default bound kills it invisibly (the raise bypasses the controller rescue).
  test "the Ask Verto message stream is on the skip tier" do
    assert_equal :skip, RequestTimeout.tier_for("POST", "/ask/threads/42/messages")
  end

  test "AI, import and export endpoints get the slow bound" do
    RequestTimeout::SLOW_ROUTES.each do |name|
      verb, path = example_request_for(name)
      assert_equal :slow, RequestTimeout.tier_for(verb, path),
                   "#{name} (#{verb} #{path}) should be on the slow tier"
      assert_equal RequestTimeout.slow_seconds, RequestTimeout.seconds_for(verb, path)
    end
  end

  test "ordinary pages get the default bound" do
    [
      [ "GET",  "/" ],
      [ "GET",  "/surveys/1" ],
      [ "GET",  "/surveys/1/results" ],
      [ "GET",  "/play/abc123" ],
      [ "POST", "/play/abc123/submit" ],
      [ "POST", "/surveys/1/render_card" ],
      [ "POST", "/surveys/1/publish" ]
    ].each do |verb, path|
      assert_equal :default, RequestTimeout.tier_for(verb, path), "#{verb} #{path}"
      assert_equal RequestTimeout.default_seconds, RequestTimeout.seconds_for(verb, path)
    end
  end

  # Same path, different verb, different tier: the GET builds the report inline
  # on a cold cache, the PATCH just saves an edit.
  test "tiers discriminate on verb, not path alone" do
    assert_equal :slow,    RequestTimeout.tier_for("GET",   "/surveys/1/results/report")
    assert_equal :default, RequestTimeout.tier_for("PATCH", "/surveys/1/results/report")
  end

  test "a format suffix does not escape the tier" do
    assert_equal :slow, RequestTimeout.tier_for("GET", "/surveys/1/results/export.csv")
    assert_equal :skip, RequestTimeout.tier_for("GET", "/surveys/1/results/summary.json")
  end

  test "dynamic segments do not match across a slash" do
    assert_equal :default, RequestTimeout.tier_for("POST", "/surveys/1/2/generate_flow")
  end

  test "bounds are env-tunable, and fall back when the value is unusable" do
    with_env("REQUEST_TIMEOUT_DEFAULT" => "10", "REQUEST_TIMEOUT_SLOW" => "600") do
      assert_equal 10,  RequestTimeout.default_seconds
      assert_equal 600, RequestTimeout.slow_seconds
    end

    with_env("REQUEST_TIMEOUT_DEFAULT" => "banana", "REQUEST_TIMEOUT_SLOW" => "") do
      assert_equal RequestTimeout::DEFAULT_SECONDS, RequestTimeout.default_seconds
      assert_equal RequestTimeout::SLOW_SECONDS,    RequestTimeout.slow_seconds
    end
  end

  test "enabled in production, off elsewhere, overridable by env" do
    with_env("REQUEST_TIMEOUT_ENABLED" => nil) do
      in_env("production")  { assert RequestTimeout.enabled? }
      in_env("development") { assert_not RequestTimeout.enabled? }
      assert_not RequestTimeout.enabled?, "must stay off in test"
    end

    with_env("REQUEST_TIMEOUT_ENABLED" => "true") { assert RequestTimeout.enabled? }
    with_env("REQUEST_TIMEOUT_ENABLED" => "false") do
      in_env("production") { assert_not RequestTimeout.enabled? }
    end
  end

  # The direct guard against the gem's railtie sneaking back in at its 15s
  # default: requiring "rack/timeout/base" must leave Rack::Timeout out of the
  # stack entirely, with only our wrapper ever inserted.
  test "the gem's own middleware is never in the stack" do
    stack = Rails.application.middleware.map(&:name)
    assert_not_includes stack, "Rack::Timeout",
                        "rack-timeout's railtie has been loaded — it bounds every request at 15s"
  end

  test "the tiered middleware is not inserted in test" do
    assert_not_includes Rails.application.middleware.map(&:name), "RequestTimeout::Middleware"
  end

  test "the middleware dispatches each tier to the right bound" do
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }
    middleware = RequestTimeout::Middleware.new(app)
    timeouts = middleware.instance_variables.each_with_object({}) do |ivar, acc|
      value = middleware.instance_variable_get(ivar)
      acc[ivar] = value.service_timeout if value.is_a?(Rack::Timeout)
    end

    assert_equal [ RequestTimeout.default_seconds, RequestTimeout.slow_seconds ].sort,
                 timeouts.values.sort
    # wait_timeout must stay off, or rack-timeout clamps the slow tier down to
    # whatever is left of the wait budget.
    middleware.instance_variables.each do |ivar|
      value = middleware.instance_variable_get(ivar)
      assert_equal false, value.wait_timeout if value.is_a?(Rack::Timeout)
    end
  end

  private

    # Builds a concrete request line from a route's own spec, so the assertions
    # exercise the same source of truth the classifier is built from.
    def example_request_for(name)
      route = Rails.application.routes.named_routes.get(name)
      path = route.path.spec.to_s
                   .sub(/\(\.:format\)\z/, "")
                   .gsub(/:[a-z_]+/, "42")
      [ route.verb, path ]
    end

    def in_env(name, &block)
      stub_method(Rails, :env, ActiveSupport::StringInquirer.new(name), &block)
    end

    def with_env(values)
      original = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
