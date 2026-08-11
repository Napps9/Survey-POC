require "test_helper"

# The leaderboard's anonymous names: assigned once per identity, unique per
# board, never editable (there is no update path to test — that absence IS the
# contract). This locks the assignment rules.
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

  test "two identities never share a name — a saturated pool falls back to a numbered variant" do
    stub_method(AnonNames, :sample, "Clever Axolotl") do
      assert_equal "Clever Axolotl",   PlayerAlias.ensure_for!(survey: @survey, key_digest: "d1").anon_name
      assert_equal "Clever Axolotl 2", PlayerAlias.ensure_for!(survey: @survey, key_digest: "d2").anon_name
      assert_equal "Clever Axolotl 3", PlayerAlias.ensure_for!(survey: @survey, key_digest: "d3").anon_name
    end
  end

  test "uniqueness is per board — the same name can appear on two different Vertos" do
    stub_method(AnonNames, :sample, "Snoozy Marmot") do
      assert_equal "Snoozy Marmot", PlayerAlias.ensure_for!(survey: @survey, key_digest: "d1").anon_name
      assert_equal "Snoozy Marmot", PlayerAlias.ensure_for!(survey: @other, key_digest: "d1").anon_name
    end
  end

  test "a digest race resolves to whoever inserted first" do
    digest = "d-race"
    interloper = nil
    # Simulate the concurrent request landing between our find and our insert.
    sneaky = ->(survey) do
      interloper ||= PlayerAlias.create!(survey: survey, key_digest: digest, anon_name: "Prior Winner")
      "Late Loser"
    end

    row = stub_method(PlayerAlias, :fresh_name_for, sneaky) do
      PlayerAlias.ensure_for!(survey: @survey, key_digest: digest)
    end

    assert_equal interloper.id, row.id
    assert_equal "Prior Winner", row.anon_name, "the loser must adopt the winner's name, not raise"
    assert_equal 1, PlayerAlias.where(survey_id: @survey.id, key_digest: digest).count
  end
end
