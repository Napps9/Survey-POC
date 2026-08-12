require "application_system_test_case"

# The board must show the finisher's own row with a "You" badge beside their
# anonymous name — inline when they make the visible top, appended after a gap
# marker when they rank below it. Rendering is client-side from the
# /leaderboard fetch, so only a browser can pin it (the endpoint's data is
# locked by leaderboard_player_test).
class LeaderboardYouRowTest < ApplicationSystemTestCase
  TYPES = [ { "id" => "gold", "name" => "Gold", "icon" => "🪙" } ].freeze
  CARDS = [
    { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[Pizza Salad],
      "tokens" => { "Pizza" => { "gold" => 5 }, "Salad" => { "gold" => 2 } } }
  ].freeze

  def board_survey
    org = Organisation.create!(name: "O", slug: "lby-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                        tokenisation_enabled: true, token_types: TYPES,
                        leaderboard_enabled: true,
                        publish_token: SecureRandom.urlsafe_base64(18),
                        published_at: Time.current)
  end

  # Simulated earlier finishers, each its own identity, totals descending from
  # `top_total` so the live run's 5 tokens lands wherever the caller wants it.
  def seed_players!(survey, count, top_total:)
    count.times do |i|
      survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed",
        player_key_digest: survey.player_key_digest("seed-#{i}"),
        token_totals: { "gold" => top_total - i },
        completed_at: (count - i).hours.ago,
        answers: { "0" => { "type" => "multiple_choice", "value" => "Pizza" } }
      )
    end
  end

  def finish_a_play!(survey)
    visit play_survey_path(survey.publish_token)
    dismiss_cookie_banner
    find(".preview-card.active .pick-item", text: "Pizza").click
    find("[data-player-target='finishBtn']").click
    assert_selector ".leaderboard-card .leaderboard-row", wait: 10
  end

  test "a top-ten finisher gets the You badge beside their anonymous name, inline" do
    survey = board_survey
    seed_players!(survey, 3, top_total: 50)

    finish_a_play!(survey)

    within ".leaderboard-card" do
      assert_selector ".leaderboard-row", count: 4
      assert_no_selector ".leaderboard-gap", visible: :all
      within ".leaderboard-row.is-you" do
        assert_selector ".leaderboard-you-badge", text: /you/i
        name = find(".leaderboard-name").text.sub(/you\z/i, "").strip
        assert name.split(" ").length >= 2, "the badge must sit beside a real anonymous name, got #{name.inspect}"
      end
    end
  end

  test "a below-the-fold finisher still appears as a row, after the gap, badge and rank intact" do
    survey = board_survey
    seed_players!(survey, 11, top_total: 60)

    finish_a_play!(survey)

    within ".leaderboard-card" do
      # Ten listed + the appended own row.
      assert_selector ".leaderboard-row", count: 11
      assert_selector ".leaderboard-gap", visible: :all
      rows = all(".leaderboard-row")
      assert rows.last.matches_css?(".is-you"), "the appended row must be the finisher's own"
      within rows.last do
        assert_selector ".leaderboard-you-badge", text: /you/i
        assert_equal "12", find(".leaderboard-rank").text, "the appended row carries the true rank"
      end
    end
  end
end
