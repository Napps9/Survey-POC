# Every Verto ends with the same three set demographic questions, appended
# automatically at creation (generate, PDF import). They give every Verto a
# comparable demographic tail — birth year, location, gender — powering the
# research collective across the platform. Cards carry "demographic" => true
# so they're identifiable downstream and never appended twice.
module DemographicQuestions
  CARDS = [
    { "type" => "open_ended", "input" => "month", "text" => "When were you born?",
      "demographic" => true },
    { "type" => "open_ended", "input" => "location", "text" => "Where do you live?",
      "description" => "Powered by OpenStreetMap — helps build a map you can explore after finishing.",
      "demographic" => true },
    { "type" => "multiple_choice", "text" => "Gender",
      "options" => [ "Male", "Female", "Non-binary", "Other", "Prefer not to say" ],
      "demographic" => true }
  ].freeze

  # The three cards resolved in `locale` (a Verto's default_locale), falling
  # back to the English above. Every Verto used to get the English tail
  # regardless of its language — a French generated Verto ended with "Where do
  # you live?". Translations live under `demographics.cards` in the locale
  # files, merged positionally; an options list is only taken whole and at the
  # registry length, because answers are positional.
  def self.cards(locale: nil)
    translated = Array(I18n.t("demographics.cards", locale: locale.presence || I18n.locale, default: nil))
    CARDS.each_with_index.map do |card, i|
      c = card.dup
      tr = translated[i]
      next c unless tr.is_a?(Hash)
      tr = tr.transform_keys(&:to_s)
      c["text"]        = tr["text"].to_s        if tr["text"].to_s.strip.present?
      c["description"] = tr["description"].to_s if tr["description"].to_s.strip.present?
      opts = tr["options"]
      c["options"] = opts.map(&:to_s) if opts.is_a?(Array) && opts.size == Array(c["options"]).size
      c
    end
  rescue I18n::InvalidLocale
    CARDS.map(&:dup)
  end

  def self.append_to(cards, locale: nil)
    list = Array(cards)
    return list if list.any? { |c| c.is_a?(Hash) && c["demographic"] }
    list + cards(locale: locale)
  end
end
