# Which parts of a stored answers hash are free text a respondent typed.
#
# One definition, because three things have to agree on it: the scrub (what to
# run the contact-detail patterns over), the hold (what to lift out of the
# answer) and the tests that pin both. Getting it wrong in either direction is
# bad — miss a slot and text nobody screened is shown; include a structured
# value and a birth month or a "CC|Region" pick gets "moderated".
#
# A slot is (answer key, "value" | "other"). It is free text when:
#
#   * it is the "other" write-in on any question card — every card type can
#     carry one (allow_other), and it is always something the respondent typed;
#   * it is the "value" of an open_ended card, unless that card is one of the
#     structured tail questions (birth month, location, a number) whose value
#     is a pick the player formats, not prose. Those are recognised the same
#     way PlayerController#sync_region_from_answers! recognises them: the
#     card's `demographic` flag plus a structured `input`.
#
# Not free text, deliberately:
#
#   * contact_form values. The card type is retired (the server refuses new
#     answers to one — see docs/DATA_RETENTION.md), but answers collected while
#     it was live are still read by the exports; those were a name and an email
#     the respondent typed into fields asking for exactly that, and scrubbing
#     the email out of an email field would corrupt data the creator was
#     entitled to collect.
#   * an answer at an index the deck no longer has. drop_retired_answers and
#     the live-edit override mean this can happen; the value is kept as it
#     always was because there is no card to say what it is. It is still run
#     through the scrub when it is a string — the patterns are safe on any text.
module Moderation
  module FreeTextSlots
    module_function

    STRUCTURED_INPUTS = %w[month location number date].freeze
    SLOTS = %w[value other].freeze

    # Yields (key, slot, text, card) for every free-text slot that currently
    # holds a String. Blank strings are skipped: there is nothing to hold.
    def each(cards, answers)
      return enum_for(:each, cards, answers) unless block_given?
      return unless answers.is_a?(Hash)

      cards = Array(cards)
      answers.each do |key, entry|
        next unless entry.is_a?(Hash)

        card = card_at(cards, key)
        SLOTS.each do |slot|
          text = entry[slot]
          next unless text.is_a?(String) && text.strip != ""
          next unless free_text?(card, slot)

          yield key, slot, text, card
        end
      end
    end

    # Is (card, slot) somewhere a respondent types prose?
    def free_text?(card, slot)
      return false if card.is_a?(Hash) && card["type"].to_s == "contact_form"
      return true  if slot == "other"
      return false unless card.is_a?(Hash)
      return false unless card["type"].to_s == "open_ended"

      !structured?(card)
    end

    # A demographic open_ended with a structured input is a formatted pick
    # ("1999-04", "GB|Kent"), not something anyone wrote.
    def structured?(card)
      card["demographic"].present? && STRUCTURED_INPUTS.include?(card["input"].to_s)
    end

    def card_at(cards, key)
      index = Integer(key.to_s, exception: false)
      return nil if index.nil? || index.negative?

      card = cards[index]
      card.is_a?(Hash) ? card : nil
    end
  end
end
