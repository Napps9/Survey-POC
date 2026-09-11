require "digest"

# Turns a Verto's deck into the rows the Language check screen reviews: one
# LINE per (card, language), carrying the words a speaker of that language
# actually reads.
#
# The screen's whole proposition is that a reviewer sees one question's wording
# in every language at once — primary first, then the secondaries — so the unit
# of review is the line, not the card and not the field. A reviewer who can
# read Spanish approves the Spanish line; they have no opinion about the French
# one and are never asked for it.
#
# Where the words live is not uniform, which is the reason this exists rather
# than each view digging into the card hash itself:
#
#   * the PRIMARY language's words are the card's canonical fields
#     (card["text"], card["options"], …) — there is no i18n entry for it
#   * every SECONDARY language's words are card["i18n"][locale], and any field
#     missing there falls back to the canonical text, because that is exactly
#     what the player renders for it (see Survey.merge_card_translations and
#     the player's own fallback). A line showing blanks where the player shows
#     English would have the reviewer approve something nobody will ever see.
#
# FIELDS is the contract, and it is the same list SurveyTranslator writes and
# Survey.swap_card_primary moves: text, description, options, pages,
# explanation, responses. A field translated anywhere in the app but missing
# here is a line a reviewer is never shown and therefore never checks — so the
# list is asserted against the translator's own tool schema in the tests rather
# than left to drift.
module LanguageCheckLines
  module_function

  # Card types that carry no respondent-facing wording of their own worth
  # reviewing in isolation. contact_form and respondent_code render chrome the
  # PLATFORM translates (config/locales), not deck text, and a welcome card's
  # title is the Verto's own title, reviewed once at the top of the screen.
  SKIPPED_TYPES = %w[].freeze

  # Ordered so the screen reads the way a card does: the question, its
  # sub-text, the answers, then the extras only some types carry.
  SCALAR_FIELDS = %w[text description explanation].freeze
  LIST_FIELDS   = %w[options responses].freeze
  PAGE_FIELD    = "pages".freeze
  FIELDS        = (SCALAR_FIELDS + LIST_FIELDS + [ PAGE_FIELD ]).freeze

  # [{ cid:, index:, type:, primary_text:, lines: [{ locale:, primary:, content: {...} }] }]
  # in deck order, one entry per card that has any reviewable words at all.
  def for(survey)
    locales = survey.verto_locales
    primary = survey.default_locale

    Array(survey.cards).each_with_index.filter_map do |card, index|
      next unless card.is_a?(Hash)
      next if SKIPPED_TYPES.include?(card["type"].to_s)

      canonical = canonical_content(card)
      next if canonical.values.all?(&:blank?)

      {
        cid:     card["cid"].to_s,
        index:   index,
        type:    card["type"].to_s,
        lines:   locales.map do |locale|
          {
            locale:  locale,
            primary: locale == primary,
            content: locale == primary ? canonical : translated_content(card, locale, canonical)
          }
        end
      }
    end
  end

  # The canonical (primary-language) words on a card, normalised to the shape
  # every line uses. Blank fields are kept as empty values rather than dropped
  # so a translated line can be compared field-for-field against it.
  def canonical_content(card)
    {
      "text"        => card["text"].to_s,
      "description" => card["description"].to_s,
      "explanation" => card["explanation"].to_s,
      "options"     => Array(card["options"]).map(&:to_s),
      "responses"   => Array(card["responses"]).filter_map { |r| r["label"].to_s if r.is_a?(Hash) },
      "pages"       => Array(card["pages"]).filter_map do |p|
        { "id" => p["id"].to_s, "text" => p["text"].to_s } if p.is_a?(Hash) && p["id"].present?
      end
    }
  end

  # One secondary language's words, with the player's own fallback applied:
  # anything this language has not been given reads in the primary language,
  # here and in the player alike.
  #
  # `fallback` (per field) is returned alongside so the screen can mark a line
  # as untranslated rather than quietly showing English under a Spanish flag —
  # the single most misleading thing this page could do.
  def translated_content(card, locale, canonical)
    entry = card.dig("i18n", locale.to_s)
    entry = {} unless entry.is_a?(Hash)

    content = {}
    fell_back = []

    SCALAR_FIELDS.each do |field|
      value = entry[field].to_s
      if value.blank? && canonical[field].present?
        content[field] = canonical[field]
        fell_back << field
      else
        content[field] = value
      end
    end

    LIST_FIELDS.each do |field|
      source = canonical[field]
      given  = Array(entry[field]).map(&:to_s)
      # Positional, and only as long as the canonical list — the alignment
      # invariant SurveyTranslator guarantees and stored answers depend on.
      # A slot with nothing in it reads in the primary language.
      content[field] = source.each_with_index.map do |canon, i|
        translated = given[i].to_s
        if translated.blank?
          fell_back << field
          canon
        else
          translated
        end
      end
    end

    by_id = Array(entry[PAGE_FIELD]).each_with_object({}) do |p, h|
      h[p["id"].to_s] = p["text"].to_s if p.is_a?(Hash)
    end
    content[PAGE_FIELD] = canonical[PAGE_FIELD].map do |page|
      text = by_id[page["id"]].to_s
      if text.blank?
        fell_back << PAGE_FIELD
        page
      else
        { "id" => page["id"], "text" => text }
      end
    end

    content.merge("untranslated" => fell_back.uniq)
  end

  # A stable hash of the words on one line. This is what an approval is
  # actually an approval OF: store it when someone approves, compare it when
  # the screen renders, and a line whose wording has moved since reads
  # "Approved, then edited" instead of carrying a tick it no longer earned.
  #
  # `untranslated` is excluded deliberately — it is a derived annotation about
  # where the words came from, not the words themselves, and including it would
  # lapse every approval on a line the moment an unrelated field was filled in.
  def digest(content)
    canonical = content.except("untranslated")
    Digest::SHA256.hexdigest(canonical.to_json)
  end

  # True when this line has no words of its own at all — every field fell back
  # to the primary language. Shown as "Not translated" rather than as text a
  # reviewer might take for a translation.
  def untranslated?(content)
    Array(content["untranslated"]).sort == present_fields(content).sort
  end

  # The fields this line actually has something in, so the view renders three
  # rows for a card with three fields rather than six with half of them blank.
  def present_fields(content)
    FIELDS.select { |f| content[f].present? }
  end
end
