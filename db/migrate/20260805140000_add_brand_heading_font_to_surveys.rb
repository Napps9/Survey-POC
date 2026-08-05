# A separate typeface for headings.
#
# brand_font (added a step earlier) set the whole Verto. Splitting headings out
# is the pairing every brand actually has: a display face for the question and
# a readable one for the answers. NULL means headings follow the body font,
# which is exactly what every existing Verto already does — so this is additive
# and changes nothing until a creator picks a second face.
class AddBrandHeadingFontToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :brand_font_heading, :string
  end
end
