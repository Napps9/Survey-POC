require "securerandom"
require "set"

class BackfillCardCids < ActiveRecord::Migration[8.1]
  # Answer-branching routes to a card by a stable opaque id (`cid`) rather than
  # its array index, so reordering/inserting/deleting cards never breaks a
  # route. Every existing card is stamped with a cid here; new cards get theirs
  # at create/serialize/sanitise time. Data-only, in the spirit of the other
  # *_cards backfills (BackfillLocationCardsToLocationInput etc.).
  def up
    Survey.reset_column_information
    Survey.find_each do |survey|
      cards = survey.read_attribute(:cards)
      next unless cards.is_a?(Array)

      used    = cards.filter_map { |c| c["cid"] if c.is_a?(Hash) && c["cid"].present? }.to_set
      changed = false
      cards.each do |card|
        next unless card.is_a?(Hash)
        next if card["cid"].present?

        cid = loop do
          candidate = "c_#{SecureRandom.hex(3)}"
          break candidate unless used.include?(candidate)
        end
        used << cid
        card["cid"] = cid
        changed = true
      end

      survey.update_column(:cards, cards) if changed
    end
  end

  def down
    # cids are inert without the logic feature, so leaving them is harmless.
  end
end
