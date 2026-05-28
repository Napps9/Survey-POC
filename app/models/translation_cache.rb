require "digest"

# Lookup table for SurveyTranslator. Avoids re-billing Claude when the same
# source card content is translated to the same target locale again — e.g.
# a small edit elsewhere triggers a full-survey re-translate, or two Vertos
# happen to share an identical question.
#
# Cache key: SHA256 of the canonical source content + source locale + target.
# Cache value: the translated card-shape hash { "text", "description", "options" }.
class TranslationCache < ApplicationRecord
  self.table_name = "translation_cache"

  validates :source_hash, :source_locale, :target_locale, presence: true

  # Stable hash of the fields SurveyTranslator actually translates. Same
  # source string + same options array (case- and whitespace-sensitive) →
  # same hash → cache hit.
  def self.source_hash_for(card)
    canonical = {
      "text"        => card["text"].to_s,
      "description" => card["description"].to_s,
      "options"     => Array(card["options"]).map(&:to_s)
    }
    Digest::SHA256.hexdigest(canonical.to_json)
  end

  # Returns an aligned array: [<translation Hash or nil>, ...] for the given
  # cards/source_locale/target_locale. nil entries are cache misses.
  def self.lookup_many(cards, source_locale:, target_locale:)
    hashes = cards.map { |c| source_hash_for(c) }
    by_hash = where(source_hash: hashes,
                    source_locale: source_locale.to_s,
                    target_locale: target_locale.to_s).index_by(&:source_hash)
    hashes.map { |h| by_hash[h]&.translation }
  end

  # Writes one entry (upsert) given a card + the SurveyTranslator output for
  # that card. No-op if the translation looks empty/malformed.
  def self.write(card, source_locale:, target_locale:, translation:)
    return unless translation.is_a?(Hash) && translation["text"].is_a?(String) && !translation["text"].empty?
    upsert(
      {
        source_hash:   source_hash_for(card),
        source_locale: source_locale.to_s,
        target_locale: target_locale.to_s,
        translation:   translation,
        created_at:    Time.current,
        updated_at:    Time.current
      },
      unique_by: :idx_translation_cache_lookup
    )
  end
end
