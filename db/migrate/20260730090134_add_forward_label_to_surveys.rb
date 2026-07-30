# The default thank-you screen's off-site button already had a URL
# (surveys.forward_url) but no label, so it always read "Visit website" — while
# *branch* end screens, stored in the end_screens JSON, have carried both a URL
# and a label all along. This gives the default screen the same pair.
class AddForwardLabelToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :forward_label, :string
  end
end
