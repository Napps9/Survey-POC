# A short ring buffer of cards removed from a deck, so a deletion survives the
# page reload that in-session undo cannot.
#
# Deliberately not a versioning gem: the need is "I deleted the wrong card, give
# it back", not a full history of every edit. A bounded list of the last few
# removals covers that at a fraction of the cost, and can't grow without limit
# inside the surveys row.
class AddDeletedCardsToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :deleted_cards, :json, default: [], null: false
  end
end
