class AddShareCopyToSurveys < ActiveRecord::Migration[8.1]
  # What a passed-on /play link says about itself. Until now a shared Verto
  # unfurled as its `theme` — the creator's internal subject line — over the
  # `description`, which is their editing brief, not a pitch to a stranger.
  # These three are the creator's own words for that moment: a narrative
  # headline and story for the link preview, and the message a respondent sends
  # with it.
  #
  # All three are nullable with no default, and that is the point: blank means
  # "fall back to what we say today" (Survey#share_title_text and friends), so
  # every Verto that already exists keeps unfurling exactly as it does now.
  # Length is capped in SurveysController#update_settings, where every other
  # creator-written column is capped — the database stays out of it.
  def change
    add_column :surveys, :share_title, :string
    add_column :surveys, :share_description, :text
    add_column :surveys, :share_message, :text
  end
end
