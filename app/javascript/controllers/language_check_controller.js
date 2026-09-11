import { Controller } from "@hotwired/stimulus"

// Progressive enhancement only, deliberately.
//
// Every action on the Language check screen is a plain form POST that works
// with no JavaScript at all — a reviewer opening the link on a phone from a
// messaging app can approve, edit and comment before any script has run, and
// the page they get back is a server render. All this controller does is fold
// the edit form and the comment thread away until they are wanted, so a deck
// of thirty cards in three languages is readable rather than a wall of
// textareas.
//
// It therefore never fetches, never mutates state, and never hides anything
// that would be unreachable without it: `hidden` is toggled on panels the
// markup already ships expanded-or-not for the right reason (a line with open
// comments arrives with them showing).
export default class extends Controller {
  static targets = ["editPanel", "editToggle", "notesPanel", "words"]
  static values = { anchor: String }

  connect() {
    // A form POST redirects back to #line-<cid>-<locale>. The browser scrolls
    // there, but a line whose edit panel was open arrives folded again, which
    // reads as "nothing happened" when in fact the save landed. Re-open it so
    // the reviewer sees their own new wording in the box they typed it in.
    if (window.location.hash === `#${this.anchorValue}` && this.hasEditPanelTarget) {
      this.element.classList.add("is-focused")
    }
  }

  toggleEdit() {
    if (!this.hasEditPanelTarget) return
    const open = this.editPanelTarget.hidden
    this.editPanelTarget.hidden = !open
    if (this.hasEditToggleTarget) this.editToggleTarget.setAttribute("aria-expanded", String(open))
    if (open) {
      const first = this.editPanelTarget.querySelector("textarea, input[type=text]")
      if (first) first.focus()
    }
  }

  toggleNotes(event) {
    if (!this.hasNotesPanelTarget) return
    const open = this.notesPanelTarget.hidden
    this.notesPanelTarget.hidden = !open
    event.currentTarget.setAttribute("aria-expanded", String(open))
    if (open) {
      const box = this.notesPanelTarget.querySelector("textarea")
      if (box) box.focus()
    }
  }
}
