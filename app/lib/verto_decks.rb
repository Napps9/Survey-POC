# The decks VertoCsvImporter knows how to reconstruct.
#
# The importer is the machinery — reading the export, matching a raw answer back
# to an option in any language, resolving countries, replaying rows as
# Responses, staying idempotent. A DECK is the part it cannot infer: whose
# survey this is, what its questions were, and what the answers to each one were
# allowed to be.
#
# Splitting them is what lets a second dataset arrive without touching a line of
# the import path that already works.
#
# ── Adding a deck ──────────────────────────────────────────────────────────
# Subclass Base in app/lib/verto_decks/, implement `specs(importer)` using the
# importer's own spec builders, and it becomes available to the rake task as
# `IMPORT_DECK=your_deck`. The option lists must be the ones actually PRESENT IN
# THE DATA, not the ones the question designer intended — an answer that matches
# no option is reported as unmatched and contributes nothing, so a plausible-
# looking list quietly shrinks the corpus.
module VertoDecks
  # The deck the importer uses when none is named, so every existing caller —
  # the rake task's defaults, the test's overrides — behaves exactly as before.
  DEFAULT = "unyo_sport".freeze

  def self.fetch(key)
    return key if key.is_a?(Base)

    const_get(key.to_s.camelize).new
  rescue NameError
    raise ArgumentError, "Unknown deck #{key.inspect}. Available: #{available.join(", ")}"
  end

  # The decks an import can actually name. A file in this directory is not
  # necessarily one of them: sibling decks share a parent that holds their
  # account and their card helpers and has no questions of its own, and
  # offering that as an importable deck would only ever be a mistake.
  def self.available
    Dir[Rails.root.join("app/lib/verto_decks/*.rb")]
      .map { |file| File.basename(file, ".rb") }
      .reject { |key| key == "base" || const_get(key.camelize).abstract? }
      .sort
  end
end
