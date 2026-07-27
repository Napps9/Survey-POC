require "test_helper"

# Verto creation runs in a background job instead of holding a Puma request
# thread for 30-120s (P0-3). These cover the hand-off, the poll contract, and
# the failure modes a creator can actually hit.
class VertoBuildTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "O", slug: "vb-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "vb-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    sign_in @user
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def with_fake_generator(&block)
    fake = Object.new
    def fake.call(**)
      { "title" => "AI title", "description" => "d", "theme" => "T", "audience_age" => "a",
        "key_insight" => "k",
        "cards" => [ { "type" => "welcome_card", "title" => "hi" },
                     { "type" => "yes_no", "text" => "Q?", "options" => %w[Yes No] } ] }
    end
    SurveyGenerator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    SurveyGenerator.singleton_class.remove_method(:new)
  end

  def submit(**overrides)
    post generate_survey_path, params: {
      theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0"
    }.merge(overrides)
  end

  test "the request enqueues the work and returns straight away" do
    assert_enqueued_with(job: BuildVertoJob) do
      submit
    end

    build = @org.verto_builds.sole
    assert_redirected_to verto_build_path(build)
    assert build.pending?
    assert_nil build.survey, "no Verto exists until the job runs"
  end

  test "the payload carries what the job needs, resolved under the request" do
    set = @org.common_question_sets.create!(name: "Core")
    q   = set.common_questions.create!(text: "Confident?", card_type: "yes_no", options: %w[Yes No])

    submit(common_question_ids: [ q.id ], locales: %w[en fr], default_locale: "en")

    payload = @org.verto_builds.sole.payload
    assert_equal "T", payload["theme"]
    assert_equal %w[en fr], payload["locales"]
    # Resolved in the request, where the org's permissions are known — the job
    # deliberately does no authorization of its own.
    assert_equal q.id, payload["common_cards"].first["common_question_id"]
  end

  test "running the job builds the Verto and completes the build" do
    build = nil
    with_fake_generator do
      perform_enqueued_jobs { submit }
    end
    build = @org.verto_builds.sole.reload

    assert build.succeeded?
    assert_not_nil build.survey
    assert_equal "AI title", build.survey.title
  end

  test "the wait screen forwards to the editor once the Verto exists" do
    with_fake_generator { perform_enqueued_jobs { submit } }
    build = @org.verto_builds.sole

    get verto_build_path(build)
    assert_redirected_to survey_path(build.reload.survey)
  end

  test "the wait screen renders while the build is still running" do
    submit
    build = @org.verto_builds.sole

    get verto_build_path(build)
    assert_response :success
    assert_select "[data-controller='verto-build']"
  end

  test "the poll endpoint reports status and a redirect when done" do
    submit
    build = @org.verto_builds.sole

    get verto_build_path(build, format: :json)
    assert_response :success
    assert_equal "pending", JSON.parse(response.body)["status"]

    survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "a", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [])
    build.succeed!(survey)

    get verto_build_path(build, format: :json)
    body = JSON.parse(response.body)
    assert_equal "succeeded", body["status"]
    assert_equal survey_path(survey), body["redirect_to"]
  end

  test "a failed generation surfaces the reason and sends the creator back" do
    boom = Object.new
    def boom.call(**) = raise("Claude is overloaded")
    SurveyGenerator.define_singleton_method(:new) { |*| boom }
    begin
      perform_enqueued_jobs { submit }
    ensure
      SurveyGenerator.singleton_class.remove_method(:new)
    end

    build = @org.verto_builds.sole.reload
    assert build.failed?
    assert_match(/overloaded/, build.error_message)

    get verto_build_path(build)
    assert_redirected_to new_survey_path
    assert_match(/couldn't generate/i, flash[:alert])
  end

  test "a build whose worker died is surfaced rather than polled forever" do
    submit
    build = @org.verto_builds.sole
    build.update_columns(status: "running", updated_at: 20.minutes.ago)

    assert build.reload.stale?
    get verto_build_path(build, format: :json)
    assert_equal "failed", JSON.parse(response.body)["status"]
  end

  test "the job is idempotent — a duplicate delivery doesn't build twice" do
    with_fake_generator do
      perform_enqueued_jobs { submit }
      build = @org.verto_builds.sole
      assert_difference -> { @org.surveys.count }, 0 do
        BuildVertoJob.perform_now(build.id)
      end
    end
  end

  test "another organisation's build is not reachable" do
    submit
    build = @org.verto_builds.sole

    other_org  = Organisation.create!(name: "Other", slug: "vb-o-#{SecureRandom.hex(3)}")
    other_user = User.create!(name: "X", email_address: "vbo-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    other_org.memberships.create!(user: other_user, role: "admin")
    delete session_path
    sign_in other_user

    get verto_build_path(build)
    assert_response :not_found
  end
end
