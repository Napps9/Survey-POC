class AddShuffleDirectionToSurveys < ActiveRecord::Migration[8.1]
  def change
    # The creator's optional steer for Shuffle: a free-text line saying what
    # they want out of the Verto's content and imagery ("warm, outdoors, small
    # groups, no offices"). Stored on the Verto rather than passed per-click so
    # the box is pre-filled next time and every later re-population — the media
    # picker's Recommended rail, a card added afterwards — leans the same way.
    # See AssetPopulator's "Direction" section.
    add_column :surveys, :shuffle_direction, :string
  end
end
