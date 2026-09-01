require "test_helper"

# The leaderboard's anonymous names: assigned once per identity, unique per
# board, never editable (there is no update path to test — that absence IS the
# contract). Names are derived deterministically from the identity digest so
# assignment never has to probe the table for a free name — the unique index
# is the only collision check. This locks the assignment rules.
class PlayerAliasTest < ActiveSupport::TestCase
  def setup
    org = Organisation.create!(name: "O", slug: "pa-#{SecureRandom.hex(3)}")
    @survey = org.surveys.create!(title: "T", theme: "T", audience_age: "all",
                                  key_insight: "x", default_locale: "en", locales: [ "en" ])
    @other = org.surveys.create!(title: "T2", theme: "T", audience_age: "all",
                                 key_insight: "x", default_locale: "en", locales: [ "en" ])
  end

  test "ensure_for! assigns once and every later call returns the same row" do
    first  = PlayerAlias.ensure_for!(survey: @survey, key_digest: "d1")
    second = PlayerAlias.ensure_for!(survey: @survey, key_digest: "d1")

    assert_equal first.id, second.id
    assert_equal first.anon_name, second.anon_name, "a name a respondent has seen must never change"
    assert_equal 1, @survey.player_aliases.count
  end

  test "names come from the curated pools" do
    name = PlayerAlias.ensure_for!(survey: @survey, key_digest: "d1").anon_name
    adjective, animal = name.split(" ", 2)

    assert_includes AnonNames::ADJECTIVES, adjective
    assert_includes AnonNames::ANIMALS, animal
  end

  test "the name is a pure function of the digest — no randomness in assignment" do
    assert_equal PlayerAlias.derived_name_for("d1"), PlayerAlias.derived_name_for("d1")
    refute_equal PlayerAlias.derived_name_for("d1"), PlayerAlias.derived_name_for("d2"),
                 "different digests should (near-)always derive different names"
  end

  test "two identities never share a name — a base-pair collision falls back to a numbered variant" do
    base = PlayerAlias.derived_name_for("d1")
    # Force every digest onto the same base pair, the way a saturated pool
    # behaves, by pinning attempt 0; later attempts run the real derivation.
    collide = ->(digest, attempt = 0) do
      attempt.zero? ? base : "#{base} #{2 + Digest::SHA256.hexdigest("#{digest}:#{attempt}").to_i(16) % 9_998}"
    end

    names = stub_method(PlayerAlias, :derived_name_for, collide) do
      %w[d1 d2 d3].map { |d| PlayerAlias.ensure_for!(survey: @survey, key_digest: d).anon_name }
    end

    assert_equal base, names.first
    assert_equal 3, names.uniq.length, "all three identities must end up with distinct names"
    names[1..].each { |n| assert_match(/\A#{Regexp.escape(base)} \d+\z/, n, "fallback is a numbered variant") }
  end

  test "uniqueness is per board — the same name can appear on two different Vertos" do
    a = PlayerAlias.ensure_for!(survey: @survey, key_digest: "d1").anon_name
    b = PlayerAlias.ensure_for!(survey: @other,  key_digest: "d1").anon_name

    assert_equal a, b, "derivation is per digest, so the same identity reads the same on any board"
  end

  test "a crowded board assigns everyone a unique name without a probe loop" do
    names = 150.times.map { |i| PlayerAlias.ensure_for!(survey: @survey, key_digest: "crowd-#{i}").anon_name }

    assert_equal 150, names.uniq.length
    assert_equal 150, @survey.player_aliases.count
  end

  test "a digest race resolves to whoever inserted first" do
    digest = "d-race"
    interloper = nil
    # Simulate the concurrent request landing between our find and our insert.
    sneaky = ->(_digest, _attempt = 0) do
      interloper ||= PlayerAlias.create!(survey: @survey, key_digest: digest, anon_name: "Prior Winner")
      "Late Loser"
    end

    row = stub_method(PlayerAlias, :derived_name_for, sneaky) do
      PlayerAlias.ensure_for!(survey: @survey, key_digest: digest)
    end

    assert_equal interloper.id, row.id
    assert_equal "Prior Winner", row.anon_name, "the loser must adopt the winner's name, not raise"
    assert_equal 1, PlayerAlias.where(survey_id: @survey.id, key_digest: digest).count
  end
end
