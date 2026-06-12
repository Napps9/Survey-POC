class AddAskRegionToSurveys < ActiveRecord::Migration[8.1]
  def change
    # "Ask players" region mode: instead of minting one share link per region
    # (impractical at hundreds of regions), respondents pick their country and
    # optionally type their area on the base link.
    add_column :surveys, :ask_region, :boolean, default: false, null: false
  end
end
