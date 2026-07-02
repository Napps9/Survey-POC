require "test_helper"

class OptionIconLibraryTest < ActiveSupport::TestCase
  test "exact label match returns inline SVG markup" do
    svg = OptionIconLibrary.svg_for("Basketball")
    assert svg.present?
    assert svg.html_safe?
    assert_match %r{\A<svg\b}, svg
    assert_includes svg, "choice-icon-svg"
  end

  test "match is case, punctuation, and whitespace tolerant" do
    base = OptionIconLibrary.svg_for("Basketball")
    assert_equal base, OptionIconLibrary.svg_for("  basketball  ")
    assert_equal base, OptionIconLibrary.svg_for("BASKETBALL!")

    golf = OptionIconLibrary.svg_for("Golf Ball")
    assert_equal golf, OptionIconLibrary.svg_for("  Golf   Ball  ")
  end

  test "multi-word label matches its full compound keyword" do
    svg = OptionIconLibrary.svg_for("Golf Ball")
    assert svg.present?
    assert_includes svg, "choice-icon-svg"
  end

  test "naive trailing-s singularisation falls back to the singular keyword" do
    assert_equal OptionIconLibrary.svg_for("Trophy"), OptionIconLibrary.svg_for("Trophy") # sanity
    svg = OptionIconLibrary.svg_for("Trophys")
    assert_equal OptionIconLibrary.svg_for("Trophy"), svg
  end

  test "unmatched label returns nil" do
    assert_nil OptionIconLibrary.svg_for("Purple")
    assert_nil OptionIconLibrary.svg_for("")
    assert_nil OptionIconLibrary.svg_for(nil)
  end

  test "returned markup carries no id or title so repeats don't duplicate DOM ids" do
    svg = OptionIconLibrary.svg_for("Trophy")
    refute_match(/\bid="/, svg)
    refute_match(%r{<title>}, svg)
    assert_includes svg, 'aria-hidden="true"'
  end

  test "every catalogued entry resolves to valid, non-empty markup" do
    OptionIconLibrary::DATA.each do |entry|
      Array(entry["keywords"]).each do |kw|
        svg = OptionIconLibrary.svg_for(kw)
        assert svg.present?, "#{entry['file']} did not resolve for keyword #{kw.inspect}"
        assert_match %r{\A<svg\b.*</svg>\z}m, svg, "#{entry['file']} did not produce a single well-formed <svg> root"
      end
    end
  end

  test "keywords are unique across the catalogue (no ambiguous matches)" do
    seen = Hash.new(0)
    OptionIconLibrary::DATA.each do |entry|
      Array(entry["keywords"]).each { |kw| seen[kw.to_s.downcase.strip] += 1 }
    end
    dupes = seen.select { |_, n| n > 1 }
    assert_empty dupes, "duplicate keyword(s) mapped to more than one icon: #{dupes.keys}"
  end
end
