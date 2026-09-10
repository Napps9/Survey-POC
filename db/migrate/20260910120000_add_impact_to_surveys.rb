# What a Verto turned out to change — the whole reason a respondent leaves an
# address at the end of one.
#
# Two halves, written months apart, and the split is the point:
#
#   next_step_*   the PROMISE, written when the Verto is published. "The
#                 council decides on 14 October." It is the creator's own
#                 sentence and it goes on the record at the moment they ask
#                 for the address, not after.
#   impact_*      what actually happened, written weeks after the Verto
#                 closed. Publishing it is what sends the mail, which is why
#                 impact_published_at exists at all: its presence is what
#                 stops a second send, so later edits are free.
#
# No impact is the ordinary case and stays comfortable — most Vertos will
# never get one. The account says the organisation hasn't said, not that
# nothing happened, because the app does not know which.
class AddImpactToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :next_step_headline, :string
    add_column :surveys, :next_step_body, :text

    add_column :surveys, :impact_headline, :string
    add_column :surveys, :impact_body, :text
    # The "what changed" lines. Optional and ordered — a creator with one
    # decision writes a sentence, and the shape must not demand three
    # achievements from a Verto that produced one.
    add_column :surveys, :impact_changes, :json, default: [], null: false
    add_column :surveys, :impact_link_url, :string
    add_column :surveys, :impact_link_label, :string
    add_column :surveys, :impact_published_at, :datetime

    # The next Verto(s) this one points at, ordered, chosen by the creator
    # from their own organisation. A wave is not a special case in the data —
    # it is another Verto the creator pointed at, and "Wave 2" is a label.
    # There is no algorithm and no cross-organisation suggestion: the only
    # fact the app has is which Verto someone played.
    add_column :surveys, :follow_up_survey_ids, :json, default: [], null: false
  end
end
