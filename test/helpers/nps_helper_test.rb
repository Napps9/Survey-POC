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

  # ── range_themes_for (auto-population / Shuffle theme matching) ────────────

  test "RANGE_THEME_KEYWORDS covers every theme slug" do
    assert_equal NpsHelper::RANGE_THEMES.sort, NpsHelper::RANGE_THEME_KEYWORDS.keys.sort
  end

  test "range_themes_for keeps only on-theme animations, best match first" do
    pool = NpsHelper.range_themes_for(%w[climate environment recycling])
    assert_includes pool, "recycling"
    assert_includes pool, "sun"
    assert_includes pool, "flowers"
    refute_includes pool, "basketball", "a sport animation must not match a climate theme"
    assert_equal "recycling", pool.first, "the strongest keyword overlap ranks first"
  end

  test "range_themes_for picks sport animations for a sport theme" do
    pool = NpsHelper.range_themes_for(%w[football team league])
    assert(pool.all? { |slug| NpsHelper::RANGE_THEME_GROUPS["Sport"].include?(slug) },
      "a football theme should only surface Sport animations, got #{pool.inspect}")
  end

  test "range_themes_for falls back to the General group when nothing is on-theme" do
    assert_equal NpsHelper::RANGE_THEME_FALLBACK, NpsHelper.range_themes_for(%w[zzz nonsense])
    assert_equal NpsHelper::RANGE_THEME_FALLBACK, NpsHelper.range_themes_for([])
  end

  test "range_themes_for is deterministic for the same keywords" do
    assert_equal NpsHelper.range_themes_for(%w[food nutrition eating]),
                 NpsHelper.range_themes_for(%w[food nutrition eating])
  end
end
