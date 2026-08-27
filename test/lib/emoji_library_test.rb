require "test_helper"

# The emoji picker's browse grid, guarded from Ruby because the repo has no JS
# test runner (same trade-off, and the same crudeness, as
# JsConstantParityTest — a shape change fails loudly rather than passing).
#
# "More emoji's needed" is the second report of this. The first, in August, was
# answered by adding a full ~1,500-glyph tier that SEARCH can reach. It came
# back because the tabs — the thing a creator actually looks at — still rendered
# only the curated set, so the library was, to the eye, however many the tabs
# held. Hence both halves below: a curated set several times bigger, and a tab
# that browses the full tier rather than requiring you to guess a word first.
class EmojiLibraryTest < ActiveSupport::TestCase
  SOURCE = File.read(Rails.root.join("app/javascript/lib/emoji_library.js")).freeze

  def categories
    block = SOURCE[/export const EMOJI_CATEGORIES = \[(.*?)\n\]/m, 1]
    assert block, "lib/emoji_library.js no longer exports EMOJI_CATEGORIES in the expected shape"
    block.split(/\n  \{/).reject(&:blank?).map do |chunk|
      {
        key:   chunk[/key:\s*"([^"]+)"/, 1],
        label: chunk[/label:\s*"([^"]+)"/, 1],
        rows:  chunk.scan(/\[\s*"([^"]+)",\s*"([^"]*)"\s*\]/)
      }
    end
  end

  def unicode_rows
    SOURCE[/export const UNICODE_EMOJI = \[(.*?)\n\]/m, 1].to_s.scan(/\[\s*"([^"]+)",\s*"([^"]*)"\s*\]/)
  end

  test "the browsable set is substantially more than a token handful" do
    total = categories.sum { |c| c[:rows].size }
    assert_operator total, :>=, 400,
                    "this is the number the second 'more emoji needed' report was about — " \
                    "the curated set is what the tabs render, and it was 128"
    assert_operator categories.size, :>=, 10,
                    "a phone keyboard has nature, food and activities tabs and this had none of them"
  end

  test "the categories a creator expects to find are there" do
    keys = categories.map { |c| c[:key] }
    %w[faces people nature food activity money health places objects symbols].each do |key|
      assert_includes keys, key
    end
  end

  test "every curated glyph carries search terms, and no category repeats one" do
    categories.each do |cat|
      cat[:rows].each do |glyph, terms|
        assert terms.present?, "#{cat[:key]}: #{glyph} has no search terms, so it is browsable but unfindable"
        assert_operator terms.split.size, :>=, 1
      end
      glyphs = cat[:rows].map(&:first)
      assert_equal glyphs.uniq, glyphs, "#{cat[:key]} lists the same glyph twice"
    end
  end

  test "the full tier is still there and still dwarfs the curated one" do
    assert_operator unicode_rows.size, :>=, 1_400,
                    "the searchable tier is what makes an unanticipated word findable"
  end

  test "the All tab has a real translated label, in every locale" do
    assert_match(/ALL_KEY\s*=/, File.read(Rails.root.join("app/javascript/controllers/emoji_picker_controller.js")),
                 "the picker no longer defines the All tab this test is about")

    SupportedLocales.codes.each do |code|
      next unless Rails.root.join("config/locales/#{code}.yml").exist?
      label = I18n.t("js.editor.emoji_all", locale: code, default: nil)
      assert label.present?, "#{code} has no js.editor.emoji_all — the tab would render a raw dotted key"
    end
  end
end
