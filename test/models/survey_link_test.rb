require "test_helper"

# SurveyLink's two jobs: minting an address nothing else in the /play/
# namespace already answers to, and resolving the three-state overrides that
# are the reason send links exist at all.
class SurveyLinkTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "O", slug: "sl-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "welcome_card", "title" => "hi" } ],
                                   publish_token: SecureRandom.urlsafe_base64(18),
                                   published_at: Time.current)
  end

  test "a name with no usable characters still produces a working address" do
    slug = SurveyLink.mint_slug(nil, fallback: "!!! ???")
    assert slug.present?
    assert_match(/\A[a-z0-9-]+\z/, slug)
  end

  test "minting steps past every kind of collision in the play namespace" do
    @survey.update!(slug: "town-hall")
    assert_equal "town-hall-2", SurveyLink.mint_slug("Town Hall")

    @survey.survey_links.create!(name: "T", slug: "town-hall-2")
    assert_equal "town-hall-3", SurveyLink.mint_slug("Town Hall")
  end

  test "a link cannot be saved onto an address already in use" do
    other = @org.surveys.create!(title: "O", theme: "O", audience_age: "all", key_insight: "x",
                                 default_locale: "en", locales: [ "en" ], cards: [],
                                 slug: "shared-name",
                                 publish_token: SecureRandom.urlsafe_base64(18),
                                 published_at: Time.current)
    assert other.persisted?

    link = @survey.survey_links.build(name: "Clash", slug: "shared-name")
    assert_not link.valid?
    assert_includes link.errors.attribute_names, :slug
  end

  test "saving a link keeps its own address" do
    link = @survey.survey_links.create!(name: "Keep", slug: "keep-me")
    link.update!(name: "Renamed")
    assert_equal "keep-me", link.reload.slug
  end

  test "a slug is normalised on the way in" do
    link = @survey.survey_links.create!(name: "N", slug: "  Summer Feedback 2026!! ")
    assert_equal "summer-feedback-2026", link.slug
  end

  test "nil overrides follow the Verto, set ones do not" do
    @survey.update!(show_results_comparison: true, share_enabled: false, regions_enabled: true)
    inherit = @survey.survey_links.create!(name: "I", slug: "inherit-all")
    pinned  = @survey.survey_links.create!(name: "P", slug: "pinned-all",
                                           show_results_comparison: false,
                                           share_enabled: true,
                                           regions_enabled: false)

    assert inherit.compare_results?
    assert_not inherit.share_button?
    assert inherit.regions_map?

    assert_not pinned.compare_results?
    assert pinned.share_button?
    assert_not pinned.regions_map?

    # The Verto answers the same three questions, so callers never branch.
    assert @survey.compare_results?
    assert_not @survey.share_button?
    assert @survey.regions_map?
  end

  test "an inheriting link moves when the Verto does" do
    @survey.update!(show_results_comparison: false)
    link = @survey.survey_links.create!(name: "I", slug: "moves-with-verto")
    assert_not link.compare_results?

    @survey.update!(show_results_comparison: true)
    assert link.reload.compare_results?
  end

  test "destroying a Verto takes its links with it" do
    @survey.survey_links.create!(name: "A", slug: "goes-away")
    assert_difference -> { SurveyLink.count }, -1 do
      @survey.destroy!
    end
  end
end
