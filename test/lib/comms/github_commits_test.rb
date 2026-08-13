require "test_helper"
require "ostruct"

# The contract that matters: every failure is [] and nothing raises, because a
# thin newsletter beats a Thursday with no draft. No test here touches the
# network — the HTTP call itself is stubbed.
class CommsGithubCommitsTest < ActiveSupport::TestCase
  def stub_response(response, &block)
    stub_method(Comms::GithubCommits, :get, response, &block)
  end

  def ok(body)
    res = Net::HTTPSuccess.allocate
    res.define_singleton_method(:body) { body }
    res
  end

  test "parses a commit list" do
    payload = [ { "sha" => "abc", "commit" => { "message" => "A change" } } ].to_json

    commits = stub_response(ok(payload)) { Comms::GithubCommits.since(1.week.ago) }
    assert_equal 1, commits.size
    assert_equal "abc", commits.first["sha"]
  end

  test "asks GitHub for the right window and branch" do
    seen = nil
    captured = ->(uri) { seen = uri; ok("[]") }

    stub_method(Comms::GithubCommits, :get, captured) do
      Comms::GithubCommits.since(Time.utc(2026, 8, 10), repo: "Owner/Repo")
    end

    assert_equal "/repos/Owner/Repo/commits", seen.path
    assert_includes seen.query, "sha=Main"
    assert_includes seen.query, "since=2026-08-10T00%3A00%3A00Z"
  end

  test "a non-200, junk JSON, a non-array body or a raised error all give []" do
    not_found = Net::HTTPNotFound.allocate
    assert_equal [], stub_response(not_found) { Comms::GithubCommits.since(1.week.ago) }

    assert_equal [], stub_response(ok("<html>nope</html>")) { Comms::GithubCommits.since(1.week.ago) }
    assert_equal [], stub_response(ok('{"message":"rate limited"}')) { Comms::GithubCommits.since(1.week.ago) }

    exploding = ->(*) { raise Errno::ECONNREFUSED }
    assert_equal [], stub_method(Comms::GithubCommits, :get, exploding) {
      Comms::GithubCommits.since(1.week.ago)
    }
  end
end
