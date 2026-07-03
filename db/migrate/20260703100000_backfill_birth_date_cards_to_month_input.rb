class BackfillBirthDateCardsToMonthInput < ActiveRecord::Migration[8.1]
  # The "When were you born?" demographic question (DemographicQuestions::CARDS)
  # is meant to always render as a native date picker restricted to month +
  # year (input: "month"). Two things could have left an existing survey's
  # copy of this card without that: it predates the input flavour existing at
  # all, or survey_editor_controller.js#serialize() rebuilt the card from the
  # DOM on a later autosave and silently dropped both `input` and
  # `demographic` (neither was read back from any dataset attribute — fixed
  # alongside this migration). Match on type + exact text rather than the
  # `demographic` flag, since that flag itself may be one of the casualties.
  def up
    Survey.reset_column_information
    Survey.find_each do |survey|
      changed = false
      updated = Array(survey.cards).map do |card|
        unless card.is_a?(Hash) && card["type"] == "open_ended" && card["text"] == "When were you born?"
          next card
        end
        next card if card["input"] == "month" && card["demographic"] == true
        changed = true
        card.merge("input" => "month", "demographic" => true)
      end
      survey.update_column(:cards, updated) if changed
    end
  end

  def down
    # Data-only backfill; the app no longer ships the old "date" flavour for
    # this question, so reverting to it isn't meaningful.
  end
end
