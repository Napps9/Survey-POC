module VertoDecks
  # The paper half of WLL Transforming Education: 3,483 classroom questionnaires
  # transcribed into the platform. Same Verto, same deck, same account as the
  # digital half — only the mode differs, which is exactly what makes the two
  # cohorts comparable rather than merely combined.
  #
  # Import the digital half first (`verto:import_csv`), then this one with
  # `verto:append_csv` — or the other way round; the deck is identical either
  # way, which is the precondition append! checks.
  class WllEducationPaper < WllEducation
    def collection_mode = "paper"
  end
end
