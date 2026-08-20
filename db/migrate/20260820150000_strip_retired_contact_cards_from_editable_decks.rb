class StripRetiredContactCardsFromEditableDecks < ActiveRecord::Migration[8.1]
  # The contact card (`contact_form`) is retired — see CardTypes.retired?.
  #
  # It can no longer be added, and the player skips any copy still in a deck,
  # so nothing more is collected either way. This clears the leftovers out of
  # the decks where clearing them is SAFE, which is a narrower set than it
  # looks: answers are keyed by card index, so pulling a card out of a deck
  # re-points every answer stored after it. A Verto that is published or has
  # any response is locked against structural edits for exactly that reason
  # (Survey#editing_locked?), and this migration honours that boundary rather
  # than working around it — those decks keep their card, inert.
  #
  # What is left, then, is drafts: no responses, never published, nothing to
  # misalign. Their creators get a clean deck instead of a card that would
  # silently vanish from the player the day they publish.
  def up
    Survey.reset_column_information

    stripped = 0
    kept     = 0

    Survey.find_each do |survey|
      cards = Array(survey.cards)
      next unless cards.any? { |c| c.is_a?(Hash) && c["type"].to_s == "contact_form" }

      if survey.editing_locked?
        kept += 1
        next
      end

      remaining = cards.reject { |c| c.is_a?(Hash) && c["type"].to_s == "contact_form" }
      survey.update_column(:cards, remaining)
      stripped += 1
    end

    say "stripped contact cards from #{stripped} editable deck(s); " \
        "left #{kept} locked deck(s) untouched (the player skips theirs)"
  end

  def down
    # Data-only. The card type no longer exists in the product, so putting the
    # cards back would restore something nothing can render or collect.
  end
end
