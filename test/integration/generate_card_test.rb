require "test_helper"

# The Add-question modal's "Generate" path posts here; the endpoint returns the
# rendered card HTML, or a JSON error the modal surfaces to the creator.
class GenerateCardTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "gen-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "gen-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(title: "T", theme: "Sport", audience_age: "under 25", key_insight: "tastes",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ])
  end

  def with_generator(impl)
    fake = Object.new
    fake.define_singleton_method(:call, &impl)
    SingleQuestionGenerator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    SingleQuestionGenerator.singleton_class.remove_method(:new)
  end

  test "returns the rendered card HTML on success" do
    card = { "type" => "yes_no", "text" => "Do you watch football?", "options" => %w[Yes No] }
    with_generator(->(**) { card }) do
      post generate_survey_card_path(@survey)
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_match "Do you watch football?", body["html"]
  end

  test "surfaces a friendly, bounded error when generation fails" do
    long = "x" * 500
    with_generator(->(**) { raise long }) do
      post generate_survey_card_path(@survey)
    end
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    refute body["ok"]
    assert body["error"].present?
    # friendly_generate_error caps the message (~200 chars + ellipsis) rather
    # than echoing the raw 500-char exception verbatim.
    assert_operator body["error"].length, :<, long.length
  end
end
