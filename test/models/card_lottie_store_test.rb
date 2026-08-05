require "test_helper"

# CardLottieStore ingests a pasted LottieFiles URL: allowlist the host, fetch
# once, prove it's really an animation, scrub the executable-ish parts, store
# it same-origin. The fetch itself is the one impure step, so it's stubbed —
# everything either side of it is asserted for real.
class CardLottieStoreTest < ActiveSupport::TestCase
  ANIMATION = {
    "v" => "5.7.4", "fr" => 30, "w" => 100, "h" => 100,
    "layers" => [ { "ty" => 4, "nm" => "shape" } ]
  }.freeze

  def setup
    @org = Organisation.create!(name: "Lottie", slug: "lot-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "S", theme: "Sports", audience_age: "all",
                                   key_insight: "x", default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "multiple_choice", "text" => "Q", "options" => %w[a b] } ])
  end

  # Swap the one impure step (the HTTP GET) for a canned body. Hand-rolled
  # rather than Minitest::Mock — minitest 6 dropped minitest/mock, and this
  # needs no gem.
  # Returns how many times the stubbed fetch was actually called.
  def with_fetch(body)
    mod = Survey::CardLottieStore
    original = mod.method(:fetch)
    calls = 0
    mod.define_singleton_method(:fetch) { |_url| calls += 1; body }
    yield
    calls
  ensure
    mod.singleton_class.remove_method(:fetch)
    mod.define_singleton_method(:fetch, original)
  end

  def attach_with(body)
    result = nil
    with_fetch(body) do
      result = Survey::CardLottieStore.fetch_and_attach(@survey, "https://lottie.host/abc/anim.json")
    end
    result
  end

  test "the source allowlist accepts LottieFiles hosts and nothing else" do
    assert Survey::CardLottieStore.source_url?("https://lottie.host/9f2/anim.json")
    assert Survey::CardLottieStore.source_url?("https://assets-v2.lottiefiles.com/a/b/anim.json")
    assert Survey::CardLottieStore.source_url?("https://assets10.lottiefiles.com/packages/lf20_x.json")

    refute Survey::CardLottieStore.source_url?("https://evil.example.com/anim.json"),
           "an arbitrary host is exactly what the allowlist exists to stop"
    refute Survey::CardLottieStore.source_url?("http://lottie.host/abc/anim.json"), "https only"
    refute Survey::CardLottieStore.source_url?("https://lottie.host/abc/anim.js"), "must be .json"
    refute Survey::CardLottieStore.source_url?("https://lottie.host.evil.com/a.json"),
           "the allowlisted host must be the WHOLE host, not a prefix"
    refute Survey::CardLottieStore.source_url?("")
  end

  test "a disallowed URL is never fetched" do
    calls = with_fetch(JSON.generate(ANIMATION)) do
      assert_nil Survey::CardLottieStore.fetch_and_attach(@survey, "https://evil.example.com/anim.json")
    end
    assert_equal 0, calls, "the allowlist must gate the request itself, not just the result"
  end

  test "a valid animation is stored as a same-origin .json blob the sanitiser accepts" do
    blob = attach_with(JSON.generate(ANIMATION))

    assert blob, "expected a stored blob"
    assert_equal "application/json", blob.content_type
    assert blob.filename.to_s.end_with?(".json"),
           "the extension is load-bearing: sanitize_lottie_url only accepts .json paths"
    assert_includes @survey.card_images.map(&:blob_id), blob.id

    path = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
    assert_equal path, Survey.sanitize_lottie_url(path),
                 "what the store produces must survive the cards sanitiser"
  end

  test "junk, non-Lottie JSON and oversized bodies are all refused" do
    assert_nil attach_with(nil),                          "a failed fetch"
    assert_nil attach_with("not json at all"),            "unparseable"
    assert_nil attach_with(JSON.generate({ "hello" => 1 })), "JSON without v/layers isn't an animation"
    assert_nil attach_with(JSON.generate({ "v" => "5", "layers" => "nope" })), "layers must be a list"
    assert_nil attach_with("x" * (Survey::CardLottieStore::MAX_BYTES + 1)), "over the byte cap"
  end

  # The vendored lottie-web is the FULL build, expressions enabled — a string
  # "x" property is evaluated at render time. Third-party JSON must not keep it.
  test "expressions are stripped and ordinary x values survive" do
    animation = {
      "v" => "5.7.4", "layers" => [ {
        "ty" => 4,
        "ks" => { "p" => { "x" => "var $bm_rt = [1,2]; $bm_rt", "k" => [ 0, 0 ] } },
        "pos" => { "x" => 42 },
        "nested" => [ { "x" => "$bm_rt = time*2" }, { "x" => { "a" => 1 } } ]
      } ]
    }
    blob = attach_with(JSON.generate(animation))
    assert blob

    stored = JSON.parse(blob.download)
    layer  = stored["layers"].first
    refute layer["ks"]["p"].key?("x"), "the expression string must be gone"
    assert_equal [ 0, 0 ], layer["ks"]["p"]["k"], "the real keyframe data must survive"
    assert_equal 42, layer["pos"]["x"], "a numeric x is animation data, not code"
    refute layer["nested"][0].key?("x"), "expressions are stripped at any depth"
    assert_equal({ "a" => 1 }, layer["nested"][1]["x"], "an object x is data too")
  end

  test "remote asset references are blanked so a stored animation never phones out" do
    animation = {
      "v" => "5.7.4", "layers" => [ { "ty" => 2 } ],
      "assets" => [
        { "id" => "image_0", "u" => "https://cdn.example.com/imgs/", "p" => "cat.png" },
        { "id" => "image_1", "u" => "", "p" => "data:image/png;base64,AAAA" }
      ]
    }
    blob = attach_with(JSON.generate(animation))
    stored = JSON.parse(blob.download)

    assert_equal "", stored["assets"][0]["u"]
    assert_equal "", stored["assets"][0]["p"], "the remote filename goes with its host"
    assert_equal "data:image/png;base64,AAAA", stored["assets"][1]["p"],
                 "an embedded base64 asset is self-contained and stays"
  end
end
