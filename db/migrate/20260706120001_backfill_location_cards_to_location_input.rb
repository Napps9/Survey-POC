class BackfillLocationCardsToLocationInput < ActiveRecord::Migration[8.1]
  # The "Where do you live?" demographic question (DemographicQuestions::CARDS)
  # now renders as the satnav-style location-search widget (input: "location")
  # instead of plain free text, so every Verto's region data comes from this
  # one universal source. Match on type + exact text rather than the
  # `demographic` flag, since that flag could be missing on older cards for
  # the same reason described in BackfillBirthDateCardsToMonthInput.
  NEW_DESCRIPTION = "Powered by OpenStreetMap — helps build a map you can explore after finishing.".freeze

  def up
    Survey.reset_column_information
    Survey.find_each do |survey|
      changed = false
      updated = Array(survey.cards).map do |card|
        unless card.is_a?(Hash) && card["type"] == "open_ended" && card["text"] == "Where do you live?"
          next card
        end
        next card if card["input"] == "location" && card["demographic"] == true
        changed = true
        card.merge("input" => "location", "demographic" => true, "description" => NEW_DESCRIPTION)
      end
      survey.update_column(:cards, updated) if changed
    end
  end

  def down
    # Data-only backfill; the app no longer ships the old plain-text flavour
    # for this question, so reverting to it isn't meaningful.
  end
end
