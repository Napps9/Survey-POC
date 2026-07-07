require "test_helper"

# The score board's "Optimise" CTA posts a flagged card here and swaps in the
# rewritten version the endpoint renders.
class OptimiseCardTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "opt-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "opt-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def survey(published: false)
    s = @org.surveys.create!(title: "T", theme: "Sport", audience_age: "under 25", key_insight: "tastes",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "multiple_choice", "text" => "Sport?", "options" => %w[A B] } ])
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current) if published
    s
  end

  def with_fake_optimiser(returns)
    fake = Object.new
    fake.define_singleton_method(:call) { |**| returns }
    CardOptimiser.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    CardOptimiser.singleton_class.remove_method(:new)
  end

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
  end

  test "optimise returns the rewritten card JSON and its rendered partial" do
    s = survey
    optimised = { "type" => "multiple_choice",
                  "text" => "Which of these sports do you most enjoy watching?",
                  "options" => %w[Football Rugby Cricket Tennis] }
    with_fake_optimiser(optimised) do
      json_post optimise_survey_card_path(s),
                index: 1, issues: [ "Only 2 answers — aim for 3-5." ],
                card: { "type" => "multiple_choice", "text" => "Sport?", "options" => %w[A B] }
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "multiple_choice", body["card"]["type"]
    assert_equal %w[Football Rugby Cricket Tennis], body["card"]["options"]
    assert_match "do you most enjoy watching", body["html"]
    assert_match 'data-card-num="2"', body["html"], "renders in place at its existing position"
  end

  test "optimise renders a rating card in place without crashing" do
    s = @org.surveys.create!(title: "T", theme: "Sport", audience_age: "under 25", key_insight: "tastes",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "rating", "text" => "Rate it", "options" => %w[Poor Excellent] } ])
    optimised = { "type" => "rating",
                  "text" => "How would you rate the political neutrality of the Olympics?",
                  "options" => %w[Poor Fair Good Great Excellent] }
    with_fake_optimiser(optimised) do
      json_post optimise_survey_card_path(s),
                index: 1, issues: [ "Getting long — 50–70 is the sweet spot (now 112)." ],
                card: { "type" => "rating", "text" => "Rate it", "options" => %w[Poor Excellent] }
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "rating", body["card"]["type"]
    assert_match "political neutrality", body["html"]
  end

  test "optimising a live Verto is locked" do
    s = survey(published: true)
    with_fake_optimiser({ "type" => "multiple_choice", "text" => "x", "options" => %w[a b c] }) do
      json_post optimise_survey_card_path(s), index: 1, issues: [],
                card: { "type" => "multiple_choice", "text" => "Sport?", "options" => %w[A B] }
    end
    assert_response :locked
  end

  test "a card with no type is rejected" do
    s = survey
    json_post optimise_survey_card_path(s), index: 1, issues: [], card: { "text" => "no type" }
    assert_response :unprocessable_entity
  end
end
