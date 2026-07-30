require "test_helper"
require "rake"

# The retention half of P0-7. Deliberately a manual task rather than a scheduled
# job — see docs/DATA_RETENTION.md — so what matters is that it does exactly
# what the operator asked and nothing more. A retention sweep that took an extra
# day's data with it would destroy a funder's research irreversibly.
class ResponsesPurgeTaskTest < ActiveSupport::TestCase
  def setup
    unless Rake::Task.task_defined?("responses:purge")
      Rake::Task.define_task(:environment)
      load Rails.root.join("lib/tasks/responses.rake")
    end
    @task = Rake::Task["responses:purge"]
    @task.reenable

    @org    = Organisation.create!(name: "O", slug: "purge-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ], cards: [])
  end

  def response_aged(days)
    r = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: {})
    r.update_columns(created_at: days.days.ago)
    r
  end

  def run_task(*args)
    @task.reenable
    capture_io { @task.invoke(*args) }
  end

  test "deletes only responses older than the cutoff" do
    old    = response_aged(400)
    recent = response_aged(10)

    run_task("365")

    assert_nil Response.find_by(id: old.id)
    assert Response.exists?(id: recent.id), "a response inside the window must survive"
  end

  test "the boundary is not off by a day" do
    # 364 days old with a 365-day retention must survive. An inclusive
    # comparison here would quietly delete an extra day of data every run.
    just_inside = response_aged(364)
    run_task("365")
    assert Response.exists?(id: just_inside.id)
  end

  test "a dry run reports without deleting" do
    old = response_aged(400)

    out, = run_task("365", "dry")

    assert Response.exists?(id: old.id), "dry run must not delete"
    assert_match(/1/, out)
    assert_match(/[Dd]ry run/, out)
  end

  test "it refuses a missing or nonsense retention period" do
    old = response_aged(400)

    [ nil, "0", "-5", "abc" ].each do |arg|
      assert_raises(SystemExit) { run_task(arg) }
      assert Response.exists?(id: old.id), "#{arg.inspect} must not delete anything"
    end
  end

  test "it says so rather than failing when there is nothing to purge" do
    response_aged(10)
    out, = run_task("365")
    assert_match(/Nothing to purge/, out)
  end

  test "purging crosses organisations, which is what a retention policy means" do
    other_org = Organisation.create!(name: "X", slug: "purge-x-#{SecureRandom.hex(3)}")
    other = other_org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                                      default_locale: "en", locales: [ "en" ], cards: [])
                     .responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: {})
    other.update_columns(created_at: 400.days.ago)

    run_task("365")
    assert_nil Response.find_by(id: other.id)
  end
end
