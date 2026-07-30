require "test_helper"

# The Flows panel's ✨ Generate modal posts here; the endpoint returns the flow
# name plus each generated card's cid + rendered editor HTML (nothing persists
# server-side — the client splices the cards and autosave saves the deck, the
# same contract as generate_card).
class GenerateFlowTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "genf-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "genf-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(title: "T", theme: "Network", audience_age: "adults", key_insight: "regions",
      default_locale: "en", locales: [ "en" ], logic: true,
      cards: [ { "type" => "multiple_choice", "cid" => "c_hub", "text" => "Which region?", "options" => %w[UK UAE USA] } ])
  end

  def with_generator(impl)
    fake = Object.new
    fake.define_singleton_method(:call, &impl)
    FlowGenerator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    FlowGenerator.singleton_class.remove_method(:new)
  end

  def post_flow(payload)
    post generate_survey_flow_path(@survey), params: payload.to_json,
         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  # Records every SurveyTranslator call so a test can assert the call *pattern*,
  # not just the result. Yields the recorder: an array of [locale, card_count].
  def with_translator
    calls = []
    fake  = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, source_locale:|
      calls << [ target_locale.to_s, Array(cards).size ]
      Array(cards).map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => Array(c["options"]) } }
    end
    SurveyTranslator.define_singleton_method(:new) { |*| fake }
    yield calls
  ensure
    SurveyTranslator.singleton_class.remove_method(:new)
  end

  test "returns the flow name and rendered cards with fresh unique cids" do
    result = { "name" => "UK",
               "cards" => [
                 { "type" => "open_ended", "text" => "How is local transport?" },
                 { "type" => "yes_no", "text" => "Are energy prices fair?", "options" => %w[Yes No] }
               ] }
    with_generator(->(**) { result }) do
      post_flow(prompt: "UK local issues", answer: "UK", entry_text: "Which region?")
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "UK", body["name"]
    assert_equal 2, body["cards"].size
    cids = body["cards"].map { |c| c["cid"] }
    assert cids.all? { |cid| cid.start_with?("c_") }
    assert_equal cids.uniq, cids
    assert_match "How is local transport?", body["cards"][0]["html"]
    assert_match cids[0], body["cards"][0]["html"], "the rendered wrap carries the stamped cid"
  end

  test "a blank prompt is rejected before any model call" do
    called = false
    with_generator(->(**) { called = true }) do
      post_flow(prompt: "   ")
    end
    assert_response :unprocessable_entity
    refute JSON.parse(response.body)["ok"]
    refute called, "the generator must not be invoked for a blank prompt"
  end

  test "surfaces a friendly, bounded error when generation fails" do
    long = "x" * 500
    with_generator(->(**) { raise long }) do
      post_flow(prompt: "UK stuff")
    end
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    refute body["ok"]
    assert body["error"].present?
    assert_operator body["error"].length, :<, long.length
  end

  test "a published Verto is locked" do
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    with_generator(->(**) { flunk "must not be called" }) do
      post_flow(prompt: "UK stuff")
    end
    assert_response :locked
  end

  # The regression guard for the 502 driver: a multilingual Verto used to make
  # one translator call PER CARD PER LOCALE, so this asserts the call pattern
  # (one per locale, each carrying the whole flow) rather than just the output.
  # Every other fixture here is single-locale, which is exactly why the fan-out
  # went unnoticed.
  test "a multilingual flow translates once per locale, carrying every card" do
    @survey.update!(locales: %w[en es fr])
    result = { "name" => "UK",
               "cards" => [
                 { "type" => "open_ended", "text" => "How is local transport?" },
                 { "type" => "yes_no", "text" => "Are energy prices fair?", "options" => %w[Yes No] },
                 { "type" => "open_ended", "text" => "Anything else?" }
               ] }

    calls = nil
    with_generator(->(**) { result }) do
      with_translator do |recorded|
        post_flow(prompt: "UK local issues", answer: "UK")
        calls = recorded
      end
    end

    assert_response :success
    assert_equal %w[es fr], calls.map(&:first).sort, "one call per secondary locale, and only those"
    assert_equal [ 3, 3 ], calls.map(&:last), "each call carries the whole flow, not a single card"
    assert_equal 2, calls.size, "3 cards x 2 locales must be 2 calls, not 6"
  end

  test "a single-locale flow makes no translator calls at all" do
    result = { "cards" => [ { "type" => "yes_no", "text" => "Fair?", "options" => %w[Yes No] } ] }
    calls = nil
    with_generator(->(**) { result }) do
      with_translator do |recorded|
        post_flow(prompt: "UK stuff")
        calls = recorded
      end
    end
    assert_response :success
    assert_empty calls, "secondary_locales is empty — the translator must not be reached"
  end

  test "the editor renders the generate-flow modal for a logic draft" do
    get survey_path(@survey)
    assert_response :success
    assert_select "[data-flows-target='modal']"
    assert_select "[data-flows-target='generatePrompt']"
    assert_match "data-flows-generate-url-value=", response.body
  end
end
