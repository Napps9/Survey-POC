# The deterministic half of free-text moderation: contact details never reach
# the database, whatever else the screen later decides.
#
# Runs on every write, before the hold, on the same patterns QuoteRedactor uses
# to clean a quote for Ask Verto — minus its bare-digit-run rule, because on a
# respondent's own answer "born in 2009" and "scored 10000" are not identifiers
# and the redactor's caller (a cross-organisation quote) tolerates a false
# positive that a stored answer should not.
#
# This is the only layer with no failure mode: no model, no job, no budget. An
# email address in an answer is gone before `resp.save!` runs, so it is never
# in the row, never in a backup, never in an export and never in a prompt. The
# hold and the screen decide what is SHOWN; this decides what is KEPT.
module Moderation
  module Scrub
    module_function

    REDACTION = QuoteRedactor::REDACTION
    PATTERNS  = QuoteRedactor::NAMED.except(:digits).freeze

    # Scrub one string. Returns [scrubbed_text, hits] where hits counts each
    # pattern that fired ({ "email" => 1, ... }), empty when nothing did.
    def call(text)
      body = text.to_s
      hits = {}
      PATTERNS.each do |name, pattern|
        count = 0
        body = body.gsub(pattern) { count += 1; REDACTION }
        hits[name.to_s] = count if count.positive?
      end
      [ body, hits ]
    end

    # Scrub every free-text slot (see FreeTextSlots) of an answers hash, plus
    # any stray String value at an index the deck has no card for. Returns
    # [answers, hits], where answers is a new hash (entries that changed are
    # copied, the rest are the same objects) and hits is keyed by answer key.
    def answers(cards, answers)
      return [ answers, {} ] unless answers.is_a?(Hash)

      all_hits = {}
      out = answers.dup
      FreeTextSlots.each(cards, answers) do |key, slot, text, _card|
        scrubbed, hits = call(text)
        next if hits.empty?

        out[key] = out[key].merge(slot => scrubbed)
        all_hits[key] = (all_hits[key] || {}).merge(hits) { |_k, a, b| a + b }
      end

      # A String value at an unknown index (no card to say what it is) is
      # still scrubbed — the patterns are safe on any text, and "no card" is
      # not a reason to keep a phone number.
      answers.each do |key, entry|
        next unless entry.is_a?(Hash) && entry["value"].is_a?(String)
        next unless FreeTextSlots.card_at(cards, key).nil?
        next if entry["type"].to_s == "contact_form"

        scrubbed, hits = call(entry["value"])
        next if hits.empty?

        out[key] = out[key].merge("value" => scrubbed)
        all_hits[key] = (all_hits[key] || {}).merge(hits) { |_k, a, b| a + b }
      end

      [ out, all_hits ]
    end
  end
end
