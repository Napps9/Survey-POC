# The country a Verto is being run for, as an ISO 3166-1 alpha-2 code
# (WorldRegions). Sits beside audience_age as the second thing a creator can say
# about who they're asking.
#
# Today it feeds one thing: the opt-in Heritage demographic question, whose
# global nine-category taxonomy reads as generic UK/US anywhere else. With a
# country set, that card is built from the five heritages people in that country
# actually identify with instead.
#
# Nullable and defaulted to nothing on purpose — an existing Verto keeps the
# global list, which is what it was published with.
class AddAudienceCountryToSurveys < ActiveRecord::Migration[8.0]
  def change
    add_column :surveys, :audience_country, :string
  end
end
