# The picture a shared /play link unfurls with, when the creator has chosen it.
#
# Until now that picture was only ever DERIVED: Survey#share_image_path walked
# consent_image → background_image → the first card image → a theme-matched
# picture from the committed library, and the editor's share card drew the
# result as a fixed thumbnail. Which is fine as a guarantee (there is always a
# picture) and useless as a decision — the one image a creator most wants to
# choose is the one a stranger sees before they have read a word, and the fall-
# through happened to hand it whichever card came first.
#
# So the fall-through stays exactly as it is, as the default, and this column is
# the override on top of it. Blank means "keep choosing for me", which is what
# every existing Verto has and what the share card's Automatic tile restores.
class AddShareImageToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :share_image, :text
  end
end
