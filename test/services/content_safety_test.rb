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

  # ── Brand-neutrality suppression (separate from the PG safety layer) ──────

  test "charged? flags protest-visual imagery by word" do
    assert ContentSafety.charged?("Crowd at a protest march")
    assert ContentSafety.charged?("Activists' placards at a rally")
    assert ContentSafety.charged?("Demonstrators picketing outside parliament square")
    assert ContentSafety.charged?("Rioting in the street at night")
  end

  test "charged? flags named protest movements by phrase even when every word is benign" do
    assert ContentSafety.charged?("Black Lives Matter mural on a wall")
    assert ContentSafety.charged?("An Extinction Rebellion banner")
    assert ContentSafety.charged?("Just Stop Oil supporters on the road")
  end

  test "charged? is not tripped by everyday scenes" do
    assert ContentSafety.neutral?("Children in a school classroom")
    assert ContentSafety.neutral?("Passengers boarding a red bus")
    assert ContentSafety.neutral?("A doctor books an appointment with a patient")
  end

  # Pins the deliberate exclusions: ambiguous words stay out of the list.
  test "charged? excludes ambiguous words by design" do
    assert ContentSafety.neutral?("A football striker scores in a strike")
    assert ContentSafety.neutral?("A police officer directing traffic")
    assert ContentSafety.neutral?("A web banner with a flag campaign")
  end

  # Pins the product boundary: the abstract-political vocabulary is HELD OUT
  # of v1 on purpose — suppressing these subjects is a product decision, not
  # an engineering default. Widening the list must be a visible diff here.
  test "charged? does not extend to abstract political vocabulary" do
    assert ContentSafety.neutral?("Diversity and equality in the workplace")
    assert ContentSafety.neutral?("A person votes at a polling station")
    assert ContentSafety.neutral?("Scales of justice on a desk")
    assert ContentSafety.neutral?("A feminism book on a shelf")
  end

  test "charged_theme? detects creator intent, including the activism topic words" do
    assert ContentSafety.charged_theme?("Activism and social justice")
    assert ContentSafety.charged_theme?("Attitudes to protest in the UK")
    refute ContentSafety.charged_theme?("Schools in north London")
    refute ContentSafety.charged_theme?("Consumer rights"),
           "broad abstract words must not become an accidental off-switch"
    refute ContentSafety.charged_theme?("Voting habits")
  end

  test "charged? treats blank text as neutral" do
    refute ContentSafety.charged?(nil)
    refute ContentSafety.charged?("")
  end
end
