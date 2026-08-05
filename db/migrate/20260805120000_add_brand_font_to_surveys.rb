# A Verto-level typeface, alongside the brand palette and background.
#
# Stored as one of RichTextSanitizer::FONT_CLASSES (e.g. "font-poppins") —
# the same seven self-hosted families the rich-text toolbar already offers per
# selection, so picking a Verto font adds no new webfont, no new request and
# nothing for the CSP to allow. NULL means the platform default (ABeeZee).
class AddBrandFontToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :brand_font, :string
  end
end
