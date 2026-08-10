module VertoDecks
  # The digital half of WLL Transforming Education: 50,835 sessions collected
  # through the player, of which 44,585 carry at least one answer.
  #
  # Its export is the reason VertoExportLayout measures the preamble and the
  # questions separately: this file is shifted by one for six preamble columns
  # and then aligned again from the first question onwards, because a header
  # with no data column ("Points") cancels the unnamed data column out.
  class WllEducationDigital < WllEducation
    def collection_mode = "digital"
  end
end
