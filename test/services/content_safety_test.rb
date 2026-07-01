require "test_helper"

class ContentSafetyTest < ActiveSupport::TestCase
  test "general unsafe terms are blocked for every audience" do
    refute ContentSafety.safe?("nude beach photo")
    refute ContentSafety.safe?("a man with a gun")
    refute ContentSafety.safe?("cocaine on a table")
    assert ContentSafety.safe?("mountains and a lake")
  end

  test "mature-but-legal terms are blocked only for young audiences" do
    assert ContentSafety.safe?("wine tasting", %w[adult]),      "wine is fine for adults"
    refute ContentSafety.safe?("wine tasting", %w[kids]),       "wine is not age-appropriate for kids"
    refute ContentSafety.safe?("casino night", %w[teen])
    assert ContentSafety.safe?("casino night", %w[adult])
  end

  test "scrub_query strips blocked words, keeping the safe subject" do
    assert_equal "beach party", ContentSafety.scrub_query("sexy beach party")
    assert_equal "party",       ContentSafety.scrub_query("beer party", %w[kids])
    assert_equal "night party",  ContentSafety.scrub_query("night casino party", %w[teen])
  end

  test "scrub_query returns empty when every term is blocked" do
    assert_equal "", ContentSafety.scrub_query("nude naked")
    assert_equal "", ContentSafety.scrub_query("beer wine vodka", %w[kids])
  end

  test "safe? treats blank text as safe" do
    assert ContentSafety.safe?(nil)
    assert ContentSafety.safe?("")
  end
end
