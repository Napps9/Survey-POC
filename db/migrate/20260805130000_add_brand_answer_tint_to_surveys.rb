# Whether a Verto's answer icon tiles derive from its brand colour.
#
# The six .choice-bg-N tiles ship as fixed pastels. With this on, they become
# a ramp of the Verto's primary colour instead, so answers look like the brand.
# Boolean rather than a palette name: the only alternative to "the product's
# pastels" that stays right when the brand colour changes is "follow the brand".
class AddBrandAnswerTintToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :brand_answer_tint, :boolean, default: false, null: false
  end
end
