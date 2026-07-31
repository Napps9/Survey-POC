require "application_system_test_case"

# BUG-024. "Is this answer given?" is decided twice — by
# `PlayerController#answered?` (which decides what a later submit may not
# overwrite) and by `_isAnswered` in player_controller.js (which decides whether
# a token-awarding card locks). They disagreed twice over, and both ways round
# cost the respondent:
#
#   * an "Other"-only answer — the client read `.value` and never looked at
#     `.other`, so it left the card unlocked and awarded nothing while the
#     server considered it answered and locked it. The respondent believed they
#     could come back to it; their correction was discarded and the points went
#     with it.
#   * an empty Hash — a grid or tap card with nothing picked. The server called
#     that answered and locked a card the respondent had skipped. Here the
#     client was right, so the rule moved on the server.
#
# Two implementations of one rule cannot be kept in step by reading them. This
# runs the SAME table through both and asserts they agree case by case — the
# behavioural equivalent of the constant parity test.
class AnswerParityTest < ApplicationSystemTestCase
  # Every shape the two sides actually see, with what "answered" must mean.
  CASES = [
    [ "nothing stored",             nil,                                     false ],
    [ "not a hash",                 "just a string",                         false ],
    [ "empty hash",                 {},                                      false ],
    [ "explicit nil value",         { "value" => nil },                      false ],
    [ "blank string",               { "value" => "" },                       false ],
    [ "whitespace string",          { "value" => "   " },                    false ],
    [ "empty array",                { "value" => [] },                       false ],
    [ "empty hash value (grid)",    { "value" => {} },                       false ],
    [ "blank other",                { "value" => nil, "other" => "  " },     false ],
    [ "a string answer",            { "value" => "Yes" },                    true ],
    [ "a numeric answer",           { "value" => 3 },                        true ],
    [ "zero is an answer",          { "value" => 0 },                        true ],
    [ "false is an answer",         { "value" => false },                    true ],
    [ "a multi-pick answer",        { "value" => [ "A", "B" ] },             true ],
    [ "a grid answer",              { "value" => { "row1" => "Agree" } },    true ],
    [ "other only",                 { "value" => nil, "other" => "Cheese" }, true ],
    [ "other alongside a value",    { "value" => "A", "other" => "Cheese" }, true ]
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "ap-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Ap", email_address: "ap-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Parity", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hello" },
               { "type" => "multiple_choice", "cid" => "q1", "text" => "Pick one",
                 "options" => %w[A B], "allow_other" => true } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  # The server's rule, reached the way the controller reaches it.
  def server_answered?(ans)
    PlayerController.new.send(:answered?, ans)
  end

  # The client's rule, evaluated in the real player.
  def client_answered
    visit play_survey_path(@survey.publish_token)
    dismiss_cookie_banner
    assert_selector "[data-player-target='card']", minimum: 1

    evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="player"]')
        const c    = app.getControllerForElementAndIdentifier(root, "player")
        return #{CASES.map { |_n, ans, _e| ans }.to_json}.map(a => c._isAnswered(a))
      })()
    JS
  end

  test "the server's answered? matches the table" do
    CASES.each do |name, ans, expected|
      assert_equal expected, server_answered?(ans), "server, #{name}: #{ans.inspect}"
    end
  end

  test "the client's _isAnswered matches the table" do
    client_answered.each_with_index do |actual, i|
      name, ans, expected = CASES[i]
      assert_equal expected, actual, "client, #{name}: #{ans.inspect}"
    end
  end

  # The one that matters: not that each is individually right, but that they
  # cannot drift apart. This is the assertion that would have caught the bug.
  test "the two implementations agree on every case" do
    client = client_answered
    disagreements = CASES.each_with_index.filter_map do |(name, ans, _expected), i|
      server = server_answered?(ans)
      "#{name} (#{ans.inspect}): server=#{server} client=#{client[i]}" if server != client[i]
    end

    assert_empty disagreements,
                 "the client decides whether a card locks and the server decides whether a " \
                 "later answer is accepted. Where they disagree the respondent either loses " \
                 "an answer they were told they could still change, or keeps editing one " \
                 "that is already fixed:\n" + disagreements.join("\n")
  end
end
