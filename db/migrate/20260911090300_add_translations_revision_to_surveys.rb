# A monotonic counter of how many times this Verto's wording has been changed
# from the Language check screen.
#
# The editor's autosave PATCHes the whole `cards` array, rebuilt from the DOM
# (survey_editor_controller#serialize) — including every language's i18n entry,
# read from a store seeded once at page load. So an editor tab that was open
# before a reviewer fixed the French would write the old French straight back
# over the new one, and nothing would say so.
#
# The editor now sends the revision it was rendered at. When that number is
# behind, SurveysController#update carries the database's wording forward for
# exactly the (cid, locale) pairs edited since — the client is not overruled
# about anything it could actually see. Same shape as keep_setup_media, which
# exists for the same class of bug during the import setup window.
class AddTranslationsRevisionToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :translations_revision, :integer, null: false, default: 0
  end
end
