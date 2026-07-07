require "test_helper"

# The editor's Rules of the Game strings (js.editor.rules.*) are mirrored
# across all 19 locale files. verto_rules.js looks keys up at runtime, so a
# missing key in any locale surfaces as a raw key string in the UI — catch
# the drift here instead.
class LocaleRulesParityTest < ActiveSupport::TestCase
  RULES_PATH = %w[js editor rules].freeze

  def rules_block(file)
    yaml = YAML.load_file(file)
    locale = File.basename(file, ".yml")
    yaml.dig(locale, *RULES_PATH) || {}
  end

  test "every locale mirrors en.yml's editor rules keys" do
    en_keys = rules_block(Rails.root.join("config/locales/en.yml")).keys.sort
    assert_includes en_keys, "ccount_ok", "sanity: en.yml carries the card-count keys"
    assert_includes en_keys, "count_odd_list", "sanity: en.yml carries the odd-list key"
    refute_includes en_keys, "length_short", "short text is no longer flagged"
    refute_includes en_keys, "qcount_ok", "question-count keys were replaced by card-count keys"

    Dir[Rails.root.join("config/locales/*.yml")].sort.each do |file|
      next if File.basename(file) == "en.yml"
      assert_equal en_keys, rules_block(file).keys.sort,
                   "#{File.basename(file)} editor.rules keys drifted from en.yml"
    end
  end
end
