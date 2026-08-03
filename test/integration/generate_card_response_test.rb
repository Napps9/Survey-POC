require "test_helper"

# The server half of BUG-030's contract. `#generate_card` pays Claude for the
# card and (on a multilingual Verto) one translation per secondary locale; the
# editor can only keep those translations if the response carries the card JSON
# alongside its HTML.
#
# The review found this side untested: the browser test injects hand-built JSON
# past the seam, so reverting the controller to `{ ok:, html: }` — the exact
# shipped bug — left every existing test green. This is the one-line assertion
# that closes that door.
class GenerateCardResponseTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "G", email_address: "gc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "gc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(
      title: "Gen", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hi" } ]
    )
  end

  FAKE_CARD = { "type" => "yes_no", "text" => "Generated question?",
                "options" => [ "Yes", "No" ] }.freeze

  class FakeGenerator
    def call(**) = FAKE_CARD.dup
  end

  test "the response carries the card JSON, not just its markup" do
    stub_method(SingleQuestionGenerator, :new, -> { FakeGenerator.new }) do
      post generate_survey_card_path(@survey), params: {}.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert body["html"].present?
    assert_equal "Generated question?", body.dig("card", "text"),
                 "without `card:` in the response, the editor cannot seed its translation " \
                 "store and the next autosave writes the card back monolingual"
  end
end
