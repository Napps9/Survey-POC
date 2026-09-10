# Properties of a translation that hold in every language, extracted so the
# parity suites and `lib/tasks/i18n.rake` check the same thing.
#
# The precedent is EnglishSpellings, which lives here for the same reason: a
# rake file cannot be tested, so anything the task must get right belongs in a
# class the suite can reach. The task's guard and the tests that verify its
# output used to be two independent regexes; when they disagreed, the task
# wrote a file the suite then rejected.
module LocaleProperties
  # An i18n interpolation name is CODE, not prose: the view passes it as a
  # keyword argument, so a translator that renames, drops or invents one raises
  # I18n::MissingInterpolationArgument at render time — in that locale only,
  # which is to say in front of a respondent and never in the `en` suite.
  #
  # Both spellings i18n accepts are recognised: `%{name}` and sprintf's
  # `%<name>s`. EnglishSpellings::PLACEHOLDER matches the same two forms but
  # keeps the delimiters (it splits on them); this one captures the name.
  PLACEHOLDER = /%[{<]([^}>]+)[}>]/

  # The CLDR categories i18n will actually consult, per locale.
  #
  # `I18n::Backend::Simple#pluralization_key` only ever looks at :zero (and
  # only at count 0), :one and :other. `few`/`many`/`two` are consulted by
  # I18n::Backend::Pluralization, which needs the rules that ship with the
  # rails-i18n gem — and this app has neither: no `gem "rails-i18n"` in the
  # Gemfile, nothing including the Pluralization module. So the hand-written
  # `few`/`many` under `flash.*` and `portfolios.member_count` in ar/he/ru/pl/uk
  # are inert today, harmless, and kept because deleting them would make
  # installing rails-i18n later a silent regression rather than an improvement.
  #
  # The consequence for NEW copy is the one that matters: supply `one` and
  # `other`, mirroring en.yml. Adding an Arabic `zero` would change rendering
  # at count 0 in Arabic and nowhere else, which is worse than the uniform
  # English-shaped approximation every other locale gets.
  CONSULTED_PLURAL_FORMS = %w[zero one two few many other].freeze
  DEFAULT_PLURAL_FORMS = %w[one other].freeze

  # Locales that must not be written in Latin script. A translator — human or
  # model — that quietly gives up returns transliteration, and nothing else
  # catches it: the placeholders match, the keys are all present, and an
  # exact-match check against English never fires.
  SCRIPTS = {
    "ar" => /\p{Arabic}/, "he" => /\p{Hebrew}/, "hi" => /\p{Devanagari}/,
    "ja" => /\p{Hiragana}|\p{Katakana}|\p{Han}/, "ko" => /\p{Hangul}/,
    "ru" => /\p{Cyrillic}/, "uk" => /\p{Cyrillic}/
  }.freeze

  # "Verto" is what this product calls a survey and "Playverto" is the brand.
  # Neither is translated, in any script.
  PRODUCT_NAMES = %w[Playverto Verto].freeze

  # An example address shown in an input placeholder is ASCII whatever the
  # language — `player.join_email_placeholder` is "your@email.com", and the
  # locales that localise it at all localise the local part and the TLD
  # ("vash@email.ru") rather than switching script, because the respondent has
  # to be able to type what it suggests. It is not prose and has no script to
  # be in.
  EMAIL_LIKE = /\S+@\S+\.\S+/

  # Below this length a string legitimately matches its English source (a proper
  # noun, a one-word label, an email placeholder), so an identical string is
  # evidence of nothing.
  VERBATIM_MIN_LENGTH = 25

  module_function

  # The interpolation names a string declares, as a Set so order doesn't matter.
  def placeholders(text)
    text.to_s.scan(PLACEHOLDER).flatten.to_set
  end

  # What's left once the parts that are Latin by design are removed. A string
  # that is nothing but a placeholder and a product name has no script to be in.
  def bare_prose(text)
    text.to_s
        .gsub(PLACEHOLDER, "")
        .gsub(EMAIL_LIKE, "")
        .gsub(Regexp.union(PRODUCT_NAMES), "")
        .strip
  end
end
