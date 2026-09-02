require "test_helper"

# The leaderboard endpoint's contract: enablement is enforced server-side, the
# identity key is only ever stored as a digest, retakes group under the
# creator's policy, and the anonymous names are stable — the same identity
# keeps the same name on every visit. Standings math itself is locked by
# token_leaderboard_test; this locks the HTTP surface.
class LeaderboardPlayerTest < ActionDispatch::IntegrationTest
  TOKEN_TYPES = [
    { "id" => "gold", "name" => "Gold Coins", "icon" => "🪙" },
    { "id" => "coal", "name" => "Coal", "icon" => "⚫" }
  ].freeze

  CARDS = [
    { "type" => "multiple_choice", "text" => "Pick one",
      "options" => %w[Pizza Salad],
      "tokens" => { "Pizza" => { "gold" => 5 }, "Salad" => { "gold" => 2, "coal" => 1 } } },
    { "type" => "rating", "text" => "Rate it", "token_award" => { "coal" => 3 } }
  ].freeze

  def board_survey(leaderboard_enabled: true, tokenisation_enabled: true, policy: "accumulate", **attrs)
    org = Organisation.create!(name: "O", slug: "lb-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS,
                        tokenisation_enabled: tokenisation_enabled, token_types: TOKEN_TYPES,
                        leaderboard_enabled: leaderboard_enabled,
                        leaderboard_retake_policy: policy,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
    JSON.parse(response.body)
  end

  # One full play: a fresh session submitting `answer` under `player_key`.
  def play!(survey, player_key:, answer: "Pizza", session: SecureRandom.uuid)
    json_post submit_survey_path(survey.publish_token),
              session_token: session, player_key: player_key,
              answers: { "0" => { "type" => "multiple_choice", "value" => answer } }
    session
  end

  test "the endpoint is refused unless the leaderboard is actually active" do
    off  = board_survey(leaderboard_enabled: false)
    get player_leaderboard_path(off.publish_token)
    assert_response :forbidden, "hiding the CTA isn't enough — the data must be refused too"

    # leaderboard_enabled without tokenisation is inert: nothing to rank.
    inert = board_survey(tokenisation_enabled: false)
    get player_leaderboard_path(inert.publish_token)
    assert_response :forbidden

    get player_leaderboard_path("no-such-token")
    assert_response :not_found

    live = board_survey
    live.update!(unpublished_at: Time.current)
    get player_leaderboard_path(live.publish_token)
    assert_response :gone
  end

  test "writes store the identity as a digest — never the raw key, and set once per response" do
    s = board_survey
    play! s, player_key: "raw-uuid-1", session: "sess-1"

    resp = s.responses.find_by(session_token: "sess-1")
    digest = s.player_key_digest("raw-uuid-1")
    assert_equal digest, resp.player_key_digest
    refute_includes resp.attributes.values.map(&:to_s), "raw-uuid-1",
      "the raw key must never land in the row"

    # A later request with a different key can't re-point the identity.
    json_post submit_survey_path(s.publish_token),
              session_token: "sess-1", player_key: "other-key",
              answers: { "1" => { "type" => "rating", "value" => 4 } }
    assert_equal digest, resp.reload.player_key_digest, "the identity is set once per response"

    # The same key in a brand-new session (a retake) produces the same digest.
    play! s, player_key: "raw-uuid-1", session: "sess-2"
    assert_equal digest, s.responses.find_by(session_token: "sess-2").player_key_digest
  end

  test "a two-player board renders unsuppressed, ranked with names from the pools" do
    s = board_survey
    play! s, player_key: "alpha", answer: "Pizza" # 5 gold
    play! s, player_key: "beta",  answer: "Salad" # 2 gold + 1 coal = 3

    get player_leaderboard_path(s.publish_token)
    body = JSON.parse(response.body)

    assert body["ok"]
    assert_equal 2, body["total_players"],
      "rows are anonymous by construction — MIN_REGION_SAMPLE_SIZE deliberately does not apply"
    assert_equal [ 1, 2 ], body["entries"].map { |e| e["rank"] }
    assert_equal [ 5, 3 ], body["entries"].map { |e| e["total"] }
    body["entries"].each do |e|
      adjective, animal = e["name"].split(" ", 2)
      assert_includes AnonNames::ADJECTIVES, adjective
      assert_includes AnonNames::ANIMALS, animal
    end
    assert_equal 2, body["entries"].map { |e| e["name"] }.uniq.size
  end

  test "retakes accumulate under the default policy, and the name never changes" do
    s = board_survey
    play! s, player_key: "gamer", answer: "Salad" # 3
    get player_leaderboard_path(s.publish_token), params: { player_key: "gamer" }
    first_name = JSON.parse(response.body)["you"]["name"]

    play! s, player_key: "gamer", answer: "Pizza" # +5
    get player_leaderboard_path(s.publish_token), params: { player_key: "gamer" }
    body = JSON.parse(response.body)

    assert_equal 8, body["you"]["total"], "two runs, one identity, summed"
    assert_equal 1, body["total_players"], "a retake is the same player, not a new row"
    assert_equal first_name, body["you"]["name"], "the anonymous name is stable across retakes"
  end

  test "you resolves by session token, by raw key for a row-less returner, and is null for strangers" do
    s = board_survey
    session = play!(s, player_key: "me", answer: "Pizza")

    get player_leaderboard_path(s.publish_token), params: { session_token: session }
    you = JSON.parse(response.body)["you"]
    assert_equal 1, you["rank"]
    assert_equal 5, you["total"]
    assert_equal 1, you["of"]

    # no_redo's straight-to-board path: a fresh session that never wrote a row
    # still finds itself by its durable key.
    get player_leaderboard_path(s.publish_token), params: { player_key: "me" }
    assert_equal 1, JSON.parse(response.body)["you"]["rank"]

    get player_leaderboard_path(s.publish_token)
    assert_nil JSON.parse(response.body)["you"]
  end

  test "entries cap at ten while you keeps your true rank further down" do
    s = board_survey
    12.times { |i| play! s, player_key: "p#{i}", answer: (i < 11 ? "Pizza" : "Salad") }

    get player_leaderboard_path(s.publish_token), params: { player_key: "p11" }
    body = JSON.parse(response.body)

    assert_equal 10, body["entries"].size
    assert_equal 12, body["total_players"]
    assert_equal 12, body["you"]["rank"], "last in: lowest total, latest achiever"
    refute body["entries"].any? { |e| e["you"] }, "rank 12 isn't in the visible top ten"
  end

  test "enabling the board mid-flight names earlier identified finishers at read time" do
    s = board_survey
    play! s, player_key: "early"
    # The alias minted at submit simulates nothing here — drop it to prove the
    # read-time backfill alone can name a bare identified row.
    s.player_aliases.delete_all

    get player_leaderboard_path(s.publish_token)
    body = JSON.parse(response.body)

    assert_equal 1, body["entries"].size
    assert body["entries"].first["name"].present?, "read-time backfill names rows submit never named"
  end

  test "the player page wires the board: values, slot, teaser, and the retake button" do
    s = board_survey
    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "[data-player-leaderboard-value='true']"
    assert_select "[data-player-retake-policy-value]", false,
      "the policy is scoring-only now — the player has nothing to read from it"
    assert_select "[data-player-no-retests-value='']"
    assert_select "[data-player-target='leaderboard']", count: 1
    assert_select ".leaderboard-tease", count: 1, text: /🏆/
    assert_select "[data-action='click->player#playAgain']", count: 1

    no_redo = board_survey(policy: "no_redo")
    get play_survey_path(no_redo.publish_token)
    assert_select "[data-action='click->player#playAgain']", false,
      "a retake the standings would ignore must not be offered"

    gated = board_survey(no_retests: true)
    get play_survey_path(gated.publish_token)
    assert_select "[data-action='click->player#playAgain']", false,
      "a retake the server would refuse must not be offered either"
    assert_select "[data-player-no-retests-value='device']"
    assert_select "[data-player-wave-value='1']"
    assert_select "[data-player-eligibility-url-value='']", count: 1 # no code, no code step to ask at

    gated.update!(respondent_code_enabled: true)
    gated.start_next_wave!
    get play_survey_path(gated.publish_token)
    assert_select "[data-player-no-retests-value='code']"
    assert_select "[data-player-wave-value='2']"
    assert_select "[data-player-eligibility-url-value=?]", eligibility_survey_url(gated.publish_token)
    assert_select "[data-action='click->player#playAgain']", count: 1, text: /Next person/

    off = board_survey(leaderboard_enabled: false)
    get play_survey_path(off.publish_token)
    assert_select "[data-player-leaderboard-value='false']"
    assert_select "[data-player-target='leaderboard']", false
    assert_select ".leaderboard-tease", false
  end

  test "declining consent purges the leaderboard identity with everything else" do
    s = board_survey
    session = play!(s, player_key: "gone")
    assert s.responses.find_by(session_token: session).player_key_digest.present?

    json_post consent_survey_path(s.publish_token), session_token: session, agreed: false
    assert_nil s.responses.find_by(session_token: session).player_key_digest,
      "a durable identity is exactly what the decline purge exists to drop"
  end

  test "identities are not recorded while the leaderboard is off" do
    s = board_survey(leaderboard_enabled: false)
    play! s, player_key: "quiet", session: "sess-q"

    assert_nil s.responses.find_by(session_token: "sess-q").player_key_digest,
      "no leaderboard, no durable identity — nothing is collected that the feature doesn't need"
  end
end
