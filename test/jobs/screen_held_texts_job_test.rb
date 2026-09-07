require "test_helper"

# The policy half of moderation: what a verdict does to a held text. The
# screener itself is stubbed; these pin the decisions, and that every
# non-decision leaves the text held.
class ScreenHeldTextsJobTest < ActiveJob::TestCase
  # Answers `call(items, audience_age:)` with a canned result, remembering
  # what it was asked.
  class FakeScreener
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls  = []
    end

    def call(items, audience_age: nil)
      @calls << { items: items, audience_age: audience_age }
      @result.respond_to?(:call) ? @result.call(items) : @result
    end
  end

  def setup
    @org    = Organisation.create!(name: "O", slug: "sj-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "under 16s", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "open_ended", "text" => "Why?" },
                                            { "type" => "open_ended", "text" => "Else?" } ])
  end

  def response_with_held(*texts)
    answers = {}
    texts.each_index { |i| answers[i.to_s] = { "type" => "open_ended", "value" => nil, "held" => { "value" => true } } }
    resp = @survey.responses.create!(session_token: SecureRandom.uuid, status: "started", answers: answers)
    texts.each_with_index do |text, i|
      resp.held_texts.create!(survey: @survey, organisation: @org, card_index: i, slot: "value", text: text,
                              text_digest: HeldText.digest_for(text), question: @survey.cards[i]["text"])
    end
    resp
  end

  def verdicts(*triples)
    { ok: true, verdicts: triples.each_with_index.to_h { |(cat, cert, note), i|
      [ i + 1, TextScreener::Verdict.new(category: cat, certainty: cert, note: note) ]
    } }
  end

  # stub_method treats a callable return value as the implementation, and the
  # fake responds to call — so hand it a lambda that returns the fake.
  def run_with(screener, resp)
    stub_method(TextScreener, :new, ->(*_a, **_k) { screener }) { ScreenHeldTextsJob.perform_now(resp.id) }
  end

  test "a confidently clean text is released back into the answer" do
    resp = response_with_held("I want cleaner parks")
    screener = FakeScreener.new(verdicts([ "clean", 0.96, nil ]))

    run_with(screener, resp)

    held = resp.held_texts.first.reload
    assert_equal "released", held.status
    assert held.auto?
    assert_equal "clean", held.category
    assert_equal "I want cleaner parks", resp.reload.answers["0"]["value"]
    assert_equal "under 16s", screener.calls.first[:audience_age]
    assert_equal "Why?", screener.calls.first[:items].first[:question]
  end

  test "a confident violation is removed, with the text kept for the retention window" do
    resp = response_with_held("My name is Carlos Pérez, 12 Calle Mayor")

    run_with(FakeScreener.new(verdicts([ "identifying", 0.93, "full name and address" ])), resp)

    held = resp.held_texts.first.reload
    assert_equal "removed", held.status
    assert_equal "full name and address", held.decision_note
    assert held.purge_after.present?
    assert_equal({ "value" => "removed" }, resp.reload.answers["0"]["held"])
    assert_nil resp.answers["0"]["value"]
  end

  test "an uncertain verdict goes to a person with the verdict attached" do
    resp = response_with_held("my teacher is useless honestly")

    run_with(FakeScreener.new(verdicts([ "identifying", 0.4, "mentions a teacher" ])), resp)

    held = resp.held_texts.first.reload
    assert_equal "review", held.status
    assert_equal "identifying", held.category
    assert_in_delta 0.4, held.certainty
    assert_equal({ "value" => true }, resp.reload.answers["0"]["held"], "still held")
  end

  test "safeguarding is never auto-decided, however certain" do
    resp = response_with_held("nobody at home feeds me and I am scared")

    run_with(FakeScreener.new(verdicts([ "safeguarding", 0.99, "possible neglect" ])), resp)

    held = resp.held_texts.first.reload
    assert_equal "safeguarding", held.status
    assert_equal "nobody at home feeds me and I am scared", held.text
    assert_nil held.purge_after
    assert_equal({ "value" => true }, resp.reload.answers["0"]["held"])
  end

  test "in review_all mode a person decides even the confident clean ones" do
    @survey.update!(moderation_mode: "review_all")
    resp = response_with_held("I want cleaner parks")

    run_with(FakeScreener.new(verdicts([ "clean", 0.99, nil ])), resp)

    assert_equal "review", resp.held_texts.first.reload.status
    assert_nil resp.reload.answers["0"]["value"]
  end

  test "a screener failure puts the texts back to pending and schedules a retry" do
    resp = response_with_held("anything")

    run_with(FakeScreener.new({ ok: false, error: "Faraday::TimeoutError: boom" }), resp)

    held = resp.held_texts.first.reload
    assert_equal "pending", held.status
    assert_equal 1, held.screen_attempts
    assert_includes held.last_screen_error, "TimeoutError"
    assert_enqueued_with(job: ScreenHeldTextsJob, args: [ resp.id ])
  end

  test "after the attempts are spent the text goes to a person, not round again" do
    resp = response_with_held("anything")
    resp.held_texts.update_all(screen_attempts: ScreenHeldTextsJob::MAX_ATTEMPTS - 1)

    run_with(FakeScreener.new({ ok: false, error: "boom" }), resp)

    held = resp.held_texts.first.reload
    assert_equal "review", held.status
    assert_equal ScreenHeldTextsJob::MAX_ATTEMPTS, held.screen_attempts
    assert_no_enqueued_jobs only: ScreenHeldTextsJob
  end

  test "a text still pending with its attempts spent goes to a person instead of waiting to be claimed" do
    resp = response_with_held("anything")
    resp.held_texts.update_all(screen_attempts: ScreenHeldTextsJob::MAX_ATTEMPTS)
    screener = FakeScreener.new(verdicts([ "clean", 0.99, nil ]))

    run_with(screener, resp)

    held = resp.held_texts.first.reload
    assert_equal "review", held.status
    assert_match(/failed/, held.verdict_note)
    assert_empty screener.calls
    assert_no_enqueued_jobs only: ScreenHeldTextsJob
  end

  test "a text the model skipped is deferred while the others are decided" do
    resp = response_with_held("first", "second")

    run_with(FakeScreener.new(verdicts([ "clean", 0.95, nil ])), resp)

    first, second = resp.held_texts.order(:card_index)
    assert_equal "released", first.reload.status
    assert_equal "pending", second.reload.status
    assert_equal 1, second.screen_attempts
  end

  test "with the screen switched off everything goes to a person and nothing is called" do
    resp = response_with_held("anything")
    screener = FakeScreener.new(verdicts([ "clean", 0.99, nil ]))
    previous = ENV["MODERATION_SCREEN_ENABLED"]
    ENV["MODERATION_SCREEN_ENABLED"] = "0"

    run_with(screener, resp)

    held = resp.held_texts.first.reload
    assert_equal "review", held.status
    assert_match(/off/, held.verdict_note)
    assert_empty screener.calls
  ensure
    previous.nil? ? ENV.delete("MODERATION_SCREEN_ENABLED") : ENV["MODERATION_SCREEN_ENABLED"] = previous
  end

  test "past the daily budget, texts wait for a person rather than spend" do
    resp = response_with_held("anything")
    screener = FakeScreener.new(verdicts([ "clean", 0.99, nil ]))
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write(Moderation.daily_budget_key, Moderation::DAILY_CAP)

    stub_method(Rails, :cache, cache) { run_with(screener, resp) }

    assert_equal "review", resp.held_texts.first.reload.status
    assert_empty screener.calls
  end

  test "the budget counts what was screened" do
    resp = response_with_held("one", "two")
    cache = ActiveSupport::Cache::MemoryStore.new

    stub_method(Rails, :cache, cache) do
      run_with(FakeScreener.new(verdicts([ "clean", 0.99, nil ], [ "clean", 0.99, nil ])), resp)
    end

    assert_equal 2, cache.read(Moderation.daily_budget_key)
  end

  test "identical text already decided in this Verto takes the same decision without a call" do
    earlier = response_with_held("nothing")
    earlier.held_texts.first.update!(status: "released", auto: true, category: "clean", certainty: 0.95)
    resp = response_with_held("nothing")
    screener = FakeScreener.new(verdicts([ "identifying", 0.99, nil ]))

    run_with(screener, resp)

    held = resp.held_texts.first.reload
    assert_equal "released", held.status
    assert_equal "clean", held.category
    assert_equal "nothing", resp.reload.answers["0"]["value"]
    assert_empty screener.calls
  end

  test "rows another job has claimed are left alone" do
    resp = response_with_held("anything")
    resp.held_texts.update_all(status: "screening")
    screener = FakeScreener.new(verdicts([ "clean", 0.99, nil ]))

    run_with(screener, resp)

    assert_equal "screening", resp.held_texts.first.reload.status
    assert_empty screener.calls
  end

  test "a job that dies mid-batch releases its claim" do
    resp = response_with_held("anything")
    exploding = FakeScreener.new(->(_items) { raise "kaboom" })

    run_with(exploding, resp)

    assert_equal "pending", resp.held_texts.first.reload.status, "claimed rows go back for the retry or the sweep"
  end

  test "a missing response is a no-op" do
    assert_nothing_raised { ScreenHeldTextsJob.perform_now(-1) }
  end
end
