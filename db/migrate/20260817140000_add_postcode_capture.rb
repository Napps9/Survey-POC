# Optional postcode/zip capture on the "Where do you live?" demographic
# question. capture_postcode is a presentation-tier toggle like the others,
# but — unlike them — it is locked once a Verto goes live
# (SurveysController::SETTINGS_LOCKED_IN_USE): toggling it mid-collection
# would ask different respondents a different question, and turning it off
# again would not erase postcodes already collected. region_postcode is
# denormalised onto the response the same way region_country/region_label
# already are (PlayerController#sync_region_from_answers!) — one column, not
# a JSON query keyed by a card index that differs per Verto.
class AddPostcodeCapture < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :capture_postcode, :boolean, default: false, null: false
    add_column :responses, :region_postcode, :string
  end
end
