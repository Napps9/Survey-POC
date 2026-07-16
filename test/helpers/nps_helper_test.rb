require "test_helper"

class NpsHelperTest < ActionView::TestCase
  test "RANGE_THEMES includes the default and only known asset folders" do
    assert_includes NpsHelper::RANGE_THEMES, NpsHelper::NPS_THEME
    assert_includes NpsHelper::RANGE_THEMES, "football"
  end

  test "nps_lottie_urls builds one asset path per frame for a known theme" do
    urls = nps_lottie_urls("football")
    assert_equal NpsHelper::NPS_FRAMES, urls.size
    assert(urls.all? { |u| u.include?("football/") && u.end_with?(".json") })
  end

  test "nps_lottie_urls falls back to the default theme for an unknown slug" do
    assert_equal nps_lottie_urls(NpsHelper::NPS_THEME), nps_lottie_urls("not_a_theme")
  end

  test "range_theme_slug returns a known card theme, default otherwise" do
    assert_equal "football", range_theme_slug({ "range_theme" => "football" })
    assert_equal NpsHelper::NPS_THEME, range_theme_slug({ "range_theme" => "not_a_theme" })
    assert_equal NpsHelper::NPS_THEME, range_theme_slug({})
    assert_equal NpsHelper::NPS_THEME, range_theme_slug(nil)
  end

  test "range_theme_picker_data lists every theme with a label and frame URLs" do
    data = range_theme_picker_data
    assert data[:label].present?
    assert_equal NpsHelper::RANGE_THEMES.size, data[:themes].size
    data[:themes].each do |t|
      assert_includes NpsHelper::RANGE_THEMES, t[:slug]
      assert t[:label].present?
      assert_equal NpsHelper::NPS_FRAMES, t[:urls].size
    end
  end

  test "RANGE_THEMES is exactly the flattened groups (single source of truth)" do
    assert_equal NpsHelper::RANGE_THEME_GROUPS.values.flatten, NpsHelper::RANGE_THEMES
    assert_includes NpsHelper::RANGE_THEME_GROUPS.values.flatten, NpsHelper::NPS_THEME
  end

  test "range_theme_groups covers every theme exactly once, each with a label" do
    slugs = range_theme_groups.flat_map { |_cat, opts| opts.map { |_label, slug| slug } }
    assert_equal NpsHelper::RANGE_THEMES.sort, slugs.sort
    assert_equal slugs, slugs.uniq, "no theme appears in two categories"
    range_theme_groups.each do |cat, opts|
      assert cat.present?
      opts.each { |label, _slug| assert label.present? }
    end
  end

  test "range_theme_picker_data groups cover all themes" do
    slugs = range_theme_picker_data[:groups].flat_map { |g| g[:slugs] }
    assert_equal NpsHelper::RANGE_THEMES.sort, slugs.sort
  end
end
