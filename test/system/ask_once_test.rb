require "application_system_test_case"

# The respondent half of "ask once": the first run answers the question, the
# second run — same device, same durable identity — never sees it, and the
# remembered answer still rides the second run's response row.
class AskOnceSystemTest < ApplicationSystemTestCase
  def setup
    super
    @org = Organisation.create!(name: "O", slug: "aos-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Ask once", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "cid" => "q0", "ask_once" => true,
          "text" => "Which industry do you work in?",
          "options" => [ "Arts", "Tech", "Health" ] },
        { "type" => "multiple_choice", "cid" => "q1",
          "text" => "How was today?",
          "options" => [ "Great", "Fine" ] }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  test "an answered ask-once question is skipped on the next run and its answer rides along" do
    # Run 1: the ask-once question is card one, answered normally.
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    assert_text "Which industry do you work in?"
    find(".choice-list-item", text: "Arts").click
    find(".preview-btn-next").click
    assert_text "How was today?"
    find(".choice-list-item", text: "Great").click
    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active", wait: 8

    first_row = wait_for_response(count: 1)
    assert_equal "Arts", first_row.answers.dig("0", "value")
    assert first_row.player_key_digest.present?, "an ask-once deck mints the durable identity"

    # Run 2: same browser, same localStorage (identity + remembered answers),
    # but a fresh session — the way a respondent actually returns (a new tab,
    # the next day). sessionStorage is per-tab and would otherwise resume the
    # same response row, which is reload behaviour, not a repeat play.
    page.execute_script("sessionStorage.clear()")
    visit "/play/#{@survey.publish_token}"
    assert_selector ".preview-card.active", wait: 5
    assert_text "How was today?"
    assert_no_text "Which industry do you work in?"
    find(".choice-list-item", text: "Fine").click
    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active", wait: 8

    rows = wait_for_response(count: 2, all: true)
    second = (rows - [ first_row ]).first
    assert_equal "Arts", second.answers.dig("0", "value"),
                 "the remembered answer rides the new run's row"
    assert_equal "Fine", second.answers.dig("1", "value")
    assert_equal first_row.player_key_digest, second.player_key_digest,
                 "both runs belong to the same identity"
  end

  private

  # Submits land via fetch after the thank-you shows — poll briefly.
  def wait_for_response(count:, all: false)
    deadline = Time.current + 8
    loop do
      rows = @survey.responses.reload.to_a
      if rows.size >= count
        return all ? rows : rows.first
      end
      raise "expected #{count} responses, got #{rows.size}" if Time.current > deadline
      sleep 0.2
    end
  end
end
