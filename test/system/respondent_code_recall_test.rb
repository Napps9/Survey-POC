require "application_system_test_case"

# The respondent half of the code card: typing a code you used before fills in
# the ask-once questions you already answered — on a device that has never seen
# this Verto.
#
# This is the case the feature exists for and the one no unit test can reach.
# "Ask once" was a promise made to a BROWSER: the answer lives in localStorage
# under a device-minted uuid, so a new phone asked everything again. Clearing
# localStorage below is exactly that new phone.
class RespondentCodeRecallSystemTest < ApplicationSystemTestCase
  CODE = "sam14".freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "rcs-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Recall", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "respondent_code", "cid" => "rc", "recall" => true,
          "text" => "Make up a code you'll remember" },
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

  test "a code entered on a new device fills in the ask-once question already answered" do
    # ── Run 1: give the code, answer everything.
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    assert_text "Make up a code you'll remember"

    find(".preview-card.active .respondent-code-input").set(CODE)
    find(".preview-card.active .play-consent-agree").click

    assert_text "Which industry do you work in?"
    find(".choice-list-item", text: "Arts").click
    find(".preview-btn-next").click
    assert_text "How was today?"
    find(".choice-list-item", text: "Great").click
    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active", wait: 8

    first = wait_for_response(count: 1)
    assert_equal "Arts", first.answers.dig("1", "value")
    assert_equal @survey.respondent_code_digest(CODE), first.respondent_code_digest

    # The code itself must never be stored as an answer. _read's default branch
    # returns null for an unknown type, so the card's text input is not read —
    # but that is the kind of thing that stays true only while something checks.
    assert_not_includes first.answers.to_json, CODE

    # ── A NEW DEVICE. Clearing localStorage takes the durable player key AND
    # the remembered ask-once answers with it, which is precisely what a
    # different phone looks like to this app.
    page.execute_script("localStorage.clear(); sessionStorage.clear()")

    visit "/play/#{@survey.publish_token}"
    assert_selector ".preview-card.active", wait: 5
    assert_text "Make up a code you'll remember"
    find(".preview-card.active .respondent-code-input").set(CODE)
    find(".preview-card.active .play-consent-agree").click

    # Straight past the ask-once question, because the server just handed its
    # answer back under this code.
    assert_text "How was today?", wait: 5
    assert_no_text "Which industry do you work in?"

    find(".choice-list-item", text: "Fine").click
    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active", wait: 8

    rows = wait_for_response(count: 2, all: true)
    second = (rows - [ first ]).first
    assert_equal "Arts", second.answers.dig("1", "value"),
                 "the recalled answer rides the new run's row, so the response stays complete"
    assert_equal "Fine", second.answers.dig("2", "value")
    assert_not_equal first.player_key_digest, second.player_key_digest,
                     "a genuinely different device — the code is what joined them, not the browser"
    assert_equal first.respondent_code_digest, second.respondent_code_digest
  end

  # The code step is hard-required — the Skip affordance was removed on the
  # owner's decision (2026-09-01): creators hang study IDs on this card, and a
  # skippable ID question is not an ID question. The card's own buttons are the
  # only way off it (SELF_DRIVING_TYPES hides the deck nav), so no skip plus a
  # refused blank means no code, no progress.
  test "the code card offers no skip and refuses a blank continue" do
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    assert_text "Make up a code you'll remember"

    assert_no_selector ".preview-card.active .play-consent-decline"

    find(".preview-card.active .play-consent-agree").click
    assert_selector ".preview-required-hint:not(.hidden)"
    assert_no_text "Which industry do you work in?"
    # Refusing a blank must not have created a row — a code prompt alone is
    # not participation.
    assert_equal 0, @survey.responses.count

    find(".preview-card.active .respondent-code-input").set(CODE)
    find(".preview-card.active .play-consent-agree").click
    assert_text "Which industry do you work in?"
    assert_no_selector ".preview-required-hint:not(.hidden)"
  end

  private

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
