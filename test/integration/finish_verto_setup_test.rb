require "test_helper"

# An import's slow tail — translation, then imagery — used to run inline on a
# request thread at the end of create_imported_survey!. It's a job now.
#
# Unlike the wizard, an import's creator is NOT held on a wait screen: they land
# in the editor while this is still running, so the deck can be saved from under
# the job. The digest guard is what stops it writing a stale deck over that save.
class FinishVertoSetupTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "O", slug: "fvs-#{SecureRandom.hex(3)}")
  end

  def survey(locales: %w[en es])
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: locales,
                         cards: [ { "type" => "yes_no", "cid" => "c_1", "text" => "Original?", "options" => %w[Yes No] } ])
  end

  # Translates by prefixing, so a merge is visible in the stored cards.
  def with_translator
    fake = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, source_locale:|
      Array(cards).map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => Array(c["options"]) } }
    end
    SurveyTranslator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    SurveyTranslator.singleton_class.remove_method(:new)
  end

  def with_no_assets
    AssetPopulator.define_singleton_method(:new) { |*| Object.new.tap { |o| o.define_singleton_method(:populate!) { nil } } }
    yield
  ensure
    AssetPopulator.singleton_class.remove_method(:new)
  end

  test "it translates a deck nobody has touched" do
    s = survey
    digest = VertoGeneration.cards_digest(s)

    with_translator do
      with_no_assets { FinishVertoSetupJob.perform_now(s.id, digest) }
    end

    assert_equal "es:Original?", s.reload.cards.first.dig("i18n", "es", "text")
  end

  # The race the guard exists for: the creator saved an edit while the
  # translation calls were in flight. Writing back would undo it.
  test "it declines to overwrite a deck edited while it was running" do
    s = survey
    digest = VertoGeneration.cards_digest(s)
    s.update!(cards: [ { "type" => "yes_no", "cid" => "c_1", "text" => "Creator's edit", "options" => %w[Yes No] } ])

    with_translator do
      with_no_assets { FinishVertoSetupJob.perform_now(s.id, digest) }
    end

    s.reload
    assert_equal "Creator's edit", s.cards.first["text"], "the creator's edit must survive"
    assert_nil s.cards.first.dig("i18n", "es"), "the translation is the thing dropped, not the edit"
  end

  test "with no digest it writes unconditionally, which is what the wizard needs" do
    s = survey
    with_translator do
      with_no_assets { VertoGeneration.translate_survey!(s) }
    end
    assert_equal "es:Original?", s.reload.cards.first.dig("i18n", "es", "text")
  end

  test "a single-locale deck needs no translation and no guard" do
    s = survey(locales: [ "en" ])
    before = s.cards
    with_translator do
      with_no_assets { FinishVertoSetupJob.perform_now(s.id, VertoGeneration.cards_digest(s)) }
    end
    assert_equal before, s.reload.cards
  end

  test "a deleted survey is a no-op rather than a crash" do
    s = survey
    id = s.id
    digest = VertoGeneration.cards_digest(s)
    s.destroy!
    assert_nothing_raised { FinishVertoSetupJob.perform_now(id, digest) }
  end

  test "the digest changes with the deck and not with anything else" do
    s = survey
    before = VertoGeneration.cards_digest(s)

    s.update!(title: "Renamed")
    assert_equal before, VertoGeneration.cards_digest(s.reload), "a rename is not a deck change"

    s.update!(cards: s.cards + [ { "type" => "open_ended", "cid" => "c_2", "text" => "New" } ])
    assert_not_equal before, VertoGeneration.cards_digest(s.reload)
  end

  test "asset population still runs even when the translation was declined" do
    s = survey
    digest = VertoGeneration.cards_digest(s)
    s.update!(cards: [ { "type" => "yes_no", "cid" => "c_1", "text" => "Edited", "options" => %w[Yes No] } ])

    populated = false
    AssetPopulator.define_singleton_method(:new) do |*|
      Object.new.tap { |o| o.define_singleton_method(:populate!) { populated = true } }
    end
    begin
      with_translator { FinishVertoSetupJob.perform_now(s.id, digest) }
    ensure
      AssetPopulator.singleton_class.remove_method(:new)
    end

    assert populated, "imagery only fills empty slots, so it's safe regardless"
  end
end

# The cold-cache report generation is a Claude call on a request thread, and it
# was the one AI path with no bound at all — the streaming report has a slot pool,
# these two callers didn't. They share that pool now, but only on the cold branch.
class ReportGenerationBulkheadTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "rpt-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "rpt-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ])
  end

  def drain_pool
    held = []
    held << true while LimitsConcurrentStreams::POOL.acquire
    held.size
  end

  def release_pool(n)
    n.times { LimitsConcurrentStreams::POOL.release }
  end

  test "a cold cache is refused rather than queued when no slot is free" do
    generated = false
    ResultsReportGenerator.define_singleton_method(:call) { |**| generated = true; "# Report" }
    n = drain_pool
    begin
      get survey_results_report_path(@survey), headers: { "Accept" => "application/json" }
    ensure
      release_pool(n)
      ResultsReportGenerator.singleton_class.remove_method(:call)
    end

    assert_response :service_unavailable
    assert_not JSON.parse(response.body)["ok"]
    assert_not generated, "it must not start a Claude call it has no thread budget for"
  end

  # The reason the guard is on the branch and not the action: a cached report is
  # one column read, and must never wait behind someone else's generation.
  test "a warm cache is served even with every slot taken" do
    @survey.update_columns(results_report: "# Cached report", results_report_response_count: 0)

    n = drain_pool
    begin
      get survey_results_report_path(@survey), headers: { "Accept" => "application/json" }
    ensure
      release_pool(n)
    end

    assert_response :success
    assert_match "Cached report", JSON.parse(response.body)["body_html"]
  end

  test "the slot is released after a successful generation" do
    ResultsReportGenerator.define_singleton_method(:call) { |**| "# Fresh" }
    begin
      get survey_results_report_path(@survey), headers: { "Accept" => "application/json" }
      assert_response :success
      # Nothing leaked: the pool is whole again.
      n = drain_pool
      release_pool(n)
      assert_operator n, :>=, 1, "the slot came back"
    ensure
      ResultsReportGenerator.singleton_class.remove_method(:call)
    end
  end

  test "the slot is released when generation raises" do
    ResultsReportGenerator.define_singleton_method(:call) { |**| raise "boom" }
    begin
      get survey_results_report_path(@survey), headers: { "Accept" => "application/json" }
      assert_response :unprocessable_entity
      n = drain_pool
      release_pool(n)
      assert_operator n, :>=, 1, "an exception must not leak the slot"
    ensure
      ResultsReportGenerator.singleton_class.remove_method(:call)
    end
  end
end
