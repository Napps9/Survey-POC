require "test_helper"

# US English, and why it had to be a language rather than a preference.
#
# "Localisation US Eng (the PDF question optimiser changed the questions from US
# Eng to UK ENG) we might need to add US eng as a language option."
#
# The cause was structural, not a bad prompt. Every generator's language
# instruction opened `return "" if locale == SupportedLocales::DEFAULT`, so an
# English Verto sent no instruction about language AT ALL — and the prompts the
# model was reading are written in British English throughout ("optimised",
# "PRIORITISE", "organisation"), with nothing to counterbalance them. Silence
# was the only thing the code could say about English, and silence meant UK.
class EnUsLocaleTest < ActiveSupport::TestCase
  # ── The registry ──────────────────────────────────────────────────────────

  test "en-US is a real language, tellable apart from en in the picker" do
    us = SupportedLocales.find("en-US")
    assert us, "en-US is not in config/supported_locales.yml"
    assert_equal "🇺🇸", us.flag

    uk = SupportedLocales.find("en")
    assert_not_equal uk.native_name, us.native_name,
                     "two entries both labelled 'English' are two entries a creator cannot choose between"
    assert_includes SupportedLocales.ui_ready.map(&:code), "en-US",
                    "it has a full locale file, so it belongs in the platform switcher too"
  end

  test "both English variants answer english?, and nothing else does" do
    assert SupportedLocales.english?("en")
    assert SupportedLocales.english?("en-US")
    assert_not SupportedLocales.english?("es")
    assert_not SupportedLocales.english?(nil)
  end

  # ── Accept-Language ───────────────────────────────────────────────────────
  # locale_from_header used to do `.split("-").first`, which threw the region
  # subtag away before looking anything up — so a US browser could only ever
  # land on plain `en` no matter what the registry held.

  test "a browser's full tag is tried before its bare language" do
    assert_equal "en-US", SupportedLocales.coerce_tag("en-US")
    assert_equal "en-US", SupportedLocales.coerce_tag("en-us"), "header casing is not the browser's promise"
    assert_equal "en",    SupportedLocales.coerce_tag("en-GB"), "there is no en-GB entry; the UK variant IS en"
    assert_equal "en",    SupportedLocales.coerce_tag("en")
  end

  test "a region we don't carry still finds its language" do
    assert_equal "pt", SupportedLocales.coerce_tag("pt-BR")
    assert_equal "es", SupportedLocales.coerce_tag("es-419")
    assert_nil SupportedLocales.coerce_tag("xx-YY")
    assert_nil SupportedLocales.coerce_tag("")
  end

  # ── The prompt instruction ────────────────────────────────────────────────

  test "English now gets an instruction instead of silence" do
    uk = PromptLanguage.instruction("en", scope: "the question text")
    us = PromptLanguage.instruction("en-US", scope: "the question text")

    assert_match(/British English/, uk)
    assert_match(/US English/, us)
    assert_not_equal uk, us, "if both variants say the same thing the setting does nothing"
  end

  test "an English variant is never told not to use English" do
    SupportedLocales::ENGLISH.each do |code|
      refute_match(/Do not use English/i, PromptLanguage.instruction(code, scope: "x"),
                   "#{code}: the generic branch's closing sentence is nonsense for an English variant, " \
                   "and a self-contradicting instruction makes output unpredictable rather than merely wrong")
    end
  end

  test "a non-English locale keeps the instruction it always had" do
    fr = PromptLanguage.instruction("fr", scope: "the question text")
    assert_match(/French \(Français\)/, fr)
    assert_match(/Do not use English/, fr)
  end

  test "every English instruction forbids converting spelling that is already right" do
    SupportedLocales::ENGLISH.each do |code|
      assert_match(/never convert spelling/i, PromptLanguage.instruction(code, scope: "x"))
    end
    assert_match(/Do not convert between English variants/i, PromptLanguage::PRESERVE_SPELLING)
  end

  # ── The generated locale file ─────────────────────────────────────────────

  test "en-US.yml is in sync with the generator, and with en.yml's structure" do
    generated = `#{Rails.root.join("bin/rails")} i18n:en_us DIFF=1 2>&1`
    assert_match(/up to date/, generated,
                 "config/locales/en-US.yml was hand-edited or en.yml moved on — " \
                 "run `bin/rails i18n:en_us`")
  end

  # Values only. `prioritise` is also a card-type SLUG — `card.badge.prioritise`
  # — and the keys are identifiers the code looks up by name in both variants.
  # Respelling those would make every lookup miss, so the transform deliberately
  # leaves them alone and so does this.
  def leaf_values(node, out = [])
    node.each_value do |v|
      case v
      when Hash  then leaf_values(v, out)
      when Array then v.each { |x| out << x.to_s }
      else out << v.to_s
      end
    end
    out
  end

  test "no British spelling survived into en-US's copy" do
    values = leaf_values(YAML.load_file(Rails.root.join("config/locales/en-US.yml")).fetch("en-US"))
    offenders = EnglishSpellings::BRITISH_TO_AMERICAN.keys.select do |word|
      values.any? { |v| v.match?(/\b#{word}\b/i) }
    end
    assert_empty offenders, "en-US still shows #{offenders.inspect} to the reader"
  end

  test "en-US's keys are untouched, so every lookup still resolves" do
    en   = YAML.load_file(Rails.root.join("config/locales/en.yml")).fetch("en")
    enus = YAML.load_file(Rails.root.join("config/locales/en-US.yml")).fetch("en-US")

    def key_paths(node, prefix = nil, out = [])
      node.each do |k, v|
        path = [ prefix, k ].compact.join(".")
        v.is_a?(Hash) ? key_paths(v, path, out) : out << path
      end
      out
    end

    assert_equal key_paths(en), key_paths(enus),
                 "a respelled KEY is a lookup that silently misses — `card.badge.prioritise` " \
                 "is asked for by that name in both variants"
  end

  test "en.yml has grown no variant spelling the word list hasn't decided about" do
    body      = File.read(Rails.root.join("config/locales/en.yml"), encoding: "UTF-8")
    undecided = EnglishSpellings.undecided(body)

    assert_empty undecided,
                 "new copy uses #{undecided.inspect}, which looks like it might differ between the " \
                 "English variants. Add each to EnglishSpellings::BRITISH_TO_AMERICAN if it does, or " \
                 "to IDENTICAL if it doesn't — then run `bin/rails i18n:en_us`. Leaving it undecided " \
                 "means en-US quietly ships a British spelling."
  end

  test "the transform keeps a label's case" do
    assert_equal "PRIORITIZE", EnglishSpellings.americanise("PRIORITISE")
    assert_equal "Organization name", EnglishSpellings.americanise("Organisation name")
    assert_equal "color", EnglishSpellings.americanise("colour")
  end

  test "the transform leaves alone the words that only look British" do
    %w[analysis promise otherwise audience sequence confidence preference].each do |word|
      assert_equal word, EnglishSpellings.americanise(word),
                   "#{word} is spelled the same in both variants — a rule, rather than a list, mangles it"
    end
  end

  # ── The importers ─────────────────────────────────────────────────────────
  # Both took `locale:` on their signature and read it nowhere, so an import had
  # no language steer of any kind — which is the path the report came from.

  test "the PDF importer's instruction carries the language and protects the source wording" do
    msg = PdfQuestionImporter.allocate.send(:import_instruction, "en-US")
    assert_match(/US English/, msg)
    assert_match(/Preserve the author's own spelling/, msg)
    assert_match(/original_text/, msg, "the transcription is what 'keep my wording' restores from")
  end

  test "the manual importer carries the same instruction, and the creator's text" do
    msg = ManualQuestionImporter.allocate.send(:import_instruction, "en-US", "Q1. What's your favorite color?")
    assert_match(/US English/, msg)
    assert_match(/Preserve the author's own spelling/, msg)
    assert_match(/favorite color/, msg)
  end
end
