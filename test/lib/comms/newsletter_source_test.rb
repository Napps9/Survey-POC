require "test_helper"

# Pure logic — no client to stub, no rows to create.
class CommsNewsletterSourceTest < ActiveSupport::TestCase
  def commit(subject, body = "", sha: "abc1234def", date: "2026-08-11T09:00:00Z")
    message = body.present? ? "#{subject}\n\n#{body}" : subject
    { "sha" => sha, "commit" => { "message" => message, "author" => { "date" => date } } }
  end

  test "week_of returns the Monday of the week, and next_monday the one after" do
    thursday = Date.new(2026, 8, 13)
    assert_equal Date.new(2026, 8, 10), Comms::NewsletterSource.week_of(thursday)
    assert_equal Date.new(2026, 8, 17), Comms::NewsletterSource.next_monday(thursday)

    # A Monday is its own week; a Sunday still belongs to the Monday before it.
    assert_equal Date.new(2026, 8, 10), Comms::NewsletterSource.week_of(Date.new(2026, 8, 10))
    assert_equal Date.new(2026, 8, 10), Comms::NewsletterSource.week_of(Date.new(2026, 8, 16))
  end

  test "digest keeps shippable commits and drops merges, reverts and bumps" do
    raw = [
      commit("The door learns who holds the key", "A body explaining it."),
      commit("Merge branch 'Main' into feature"),
      commit("Bump rails from 8.1.2 to 8.1.3"),
      commit("Revert \"a bad idea\""),
      commit("wip"),
      commit("Real change number two")
    ]

    out = Comms::NewsletterSource.digest(raw)
    assert_equal [ "The door learns who holds the key", "Real change number two" ],
                 out.map { |c| c["subject"] }
  end

  test "digest dedupes by subject and strips commit trailers from the body" do
    raw = [
      commit("Same thing", "Why it matters.\n\nCo-Authored-By: Someone <a@b.c>\nClaude-Session: https://x"),
      commit("same THING", "A cherry-picked twin.")
    ]

    out = Comms::NewsletterSource.digest(raw)
    assert_equal 1, out.size
    assert_equal "Why it matters.", out.first["body"]
    assert_equal "abc1234", out.first["sha"]
  end

  test "digest ignores malformed entries and caps the list" do
    assert_equal [], Comms::NewsletterSource.digest(nil)
    assert_equal [], Comms::NewsletterSource.digest([ {}, { "commit" => {} }, "nonsense" ])

    many = Array.new(60) { |i| commit("Change number #{i}") }
    assert_equal Comms::NewsletterSource::MAX_COMMITS, Comms::NewsletterSource.digest(many).size
  end

  test "digest truncates a runaway body" do
    out = Comms::NewsletterSource.digest([ commit("A change", "x" * 2000) ])
    assert_operator out.first["body"].length, :<=, Comms::NewsletterSource::MAX_BODY_CHARS
  end

  test "fallback_copy is a complete, sendable edition built from subjects" do
    commits = Array.new(8) { |i| { "subject" => "Change #{i}", "body" => "ignored" } }
    copy = Comms::NewsletterSource.fallback_copy(commits, Date.new(2026, 8, 10))

    assert copy["subject"].present?
    assert copy["preheader"].present?
    assert copy["intro"].present?
    assert copy["cta_label"].present?
    assert_equal "fallback", copy["source"]
    assert_equal 6, copy["items"].size, "caps at six items"
    assert_equal "Change 0", copy["items"].first["title"]
    assert_equal "", copy["items"].first["body"], "developer bodies never reach a customer"
  end

  test "fallback_copy survives a week with no commits at all" do
    copy = Comms::NewsletterSource.fallback_copy([], Date.new(2026, 8, 10))
    assert copy["subject"].present?
    assert_equal [], copy["items"]
  end
end
