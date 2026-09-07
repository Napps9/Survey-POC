require "test_helper"

# PlayerController#show serves the rendered player HTML from Rails.cache
# (cached_play_page): the same bytes for every respondent on a given link +
# resolved locale, busted by anything that changes those bytes. The suite runs
# on the null cache store (fetch is a pass-through), so swap in a real store to
# observe the caching itself.
class PlayerPageCacheTest < ActionDispatch::IntegrationTest
  def published_survey(theme: "Sports")
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: theme, theme: theme, audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] } ]
    )
    survey.update!(publish_token: SecureRandom.hex(8))
    survey
  end

  def with_memory_cache
    old = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = old
  end

  test "the play page is served from cache and a republish busts it" do
    survey = published_survey(theme: "Sports")

    with_memory_cache do
      get play_survey_path(survey.publish_token)
      assert_response :success
      assert_includes @response.body, "Sports", "first render reaches the deck's theme"

      # Change a rendered field WITHOUT bumping updated_at: the key is unchanged,
      # so the cached bytes must still be served.
      survey.update_columns(theme: "Cricket")
      get play_survey_path(survey.publish_token)
      assert_response :success
      assert_includes @response.body, "Sports", "unchanged updated_at → still the cached page"
      assert_not_includes @response.body, "Cricket"

      # A real edit bumps updated_at → the key changes → re-render.
      survey.touch
      get play_survey_path(survey.publish_token)
      assert_response :success
      assert_includes @response.body, "Cricket", "a republish re-renders the page"
    end
  end

  test "the cache key separates two links to the same Verto" do
    survey = published_survey(theme: "Sports")
    link = survey.survey_links.create!(slug: "vanity-#{SecureRandom.hex(3)}", name: "Q1")

    with_memory_cache do
      get play_survey_path(survey.publish_token)
      assert_response :success
      body_via_token = @response.body

      get play_survey_path(link.slug)
      assert_response :success
      # Each link embeds its own token in every data-*-url the shell reads, so
      # the two responses are cached separately and each carries its own token.
      assert_includes body_via_token, survey.publish_token
      assert_includes @response.body, link.slug
    end
  end
end
