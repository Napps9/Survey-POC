require "test_helper"

# The responder half of the anonymous-name system (PlayerAlias is the
# leaderboard half): derived from the code digest, assigned once, unique per
# Verto. The extra rule the leaderboard doesn't carry: a candidate already
# naming a PLAYER on the Verto is skipped, because the export shows the two
# name columns side by side and one name in both would read as the same
# person when the identities are deliberately unlinkable.
class RespondentAliasTest < ActiveSupport::TestCase
  def setup
    org = Organisation.create!(name: "O", slug: "ra-#{SecureRandom.hex(3)}")
    @survey = org.surveys.create!(title: "T", theme: "T", audience_age: "all",
                                  key_insight: "x", default_locale: "en", locales: [ "en" ])
    @other = org.surveys.create!(title: "T2", theme: "T", audience_age: "all",
                                 key_insight: "x", default_locale: "en", locales: [ "en" ])
  end

  test "ensure_for! assigns once and every later call returns the same row" do
    first  = RespondentAlias.ensure_for!(survey: @survey, code_digest: "d1")
    second = RespondentAlias.ensure_for!(survey: @survey, code_digest: "d1")

    assert_equal first.id, second.id
    assert_equal first.anon_name, second.anon_name, "a name a creator has seen must never change"
    assert_equal 1, @survey.respondent_aliases.count
  end

  test "the name is the digest's derived pair, from the curated pools" do
    name = RespondentAlias.ensure_for!(survey: @survey, code_digest: "d1").anon_name

    assert_equal PlayerAlias.derived_name_for("d1", 0), name
    adjective, animal = name.split(" ", 2)
    assert_includes AnonNames::ADJECTIVES, adjective
    assert_includes AnonNames::ANIMALS, animal
  end

  test "a name already taken by another responder moves to the next candidate" do
    RespondentAlias.create!(survey: @survey, code_digest: "other",
                            anon_name: PlayerAlias.derived_name_for("d1", 0))

    assert_equal PlayerAlias.derived_name_for("d1", 1),
                 RespondentAlias.ensure_for!(survey: @survey, code_digest: "d1").anon_name
  end

  test "a name on the survey's leaderboard is never handed to a responder" do
    PlayerAlias.create!(survey: @survey, key_digest: "p1",
                        anon_name: PlayerAlias.derived_name_for("d1", 0))

    assert_equal PlayerAlias.derived_name_for("d1", 1),
                 RespondentAlias.ensure_for!(survey: @survey, code_digest: "d1").anon_name
  end

  test "derivation makes the same identity wear the same name on another Verto" do
    a = RespondentAlias.ensure_for!(survey: @survey, code_digest: "d1").anon_name
    b = RespondentAlias.ensure_for!(survey: @other, code_digest: "d1").anon_name

    assert_equal a, b, "same digest, clean boards — the derived attempt-0 pair both times"
  end

  test "a digest race resolves to whoever inserted first" do
    digest = "d-race"
    interloper = nil
    sneaky = ->(_digest, _attempt) do
      interloper ||= RespondentAlias.create!(survey: @survey, code_digest: digest, anon_name: "Prior Winner")
      "Late Loser"
    end

    row = stub_method(PlayerAlias, :derived_name_for, sneaky) do
      RespondentAlias.ensure_for!(survey: @survey, code_digest: digest)
    end

    assert_equal interloper.id, row.id
    assert_equal "Prior Winner", row.anon_name
    assert_equal 1, RespondentAlias.where(survey_id: @survey.id, code_digest: digest).count
  end
end
