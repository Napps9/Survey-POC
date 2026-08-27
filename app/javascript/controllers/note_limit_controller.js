import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// Two limits on one field, both on screen.
//
// The points-intro notes (tokens_note, leaderboard_note) have always been
// capped at 200 characters, but the cap was the only number a creator could
// discover — and only by hitting it. The number that actually matters is
// lower: each note renders as a single pill on the points intro
// (player/_token_intro.html.erb) and the shipped default is 101 characters, so
// past about 120 it wraps into a paragraph on a phone. Showing one limit
// taught the wrong one.
//
// So both are shown, and crossing the recommended one produces the advice that
// a creator with that much to say actually needs: this is a card, not a note.
// The hard cap stays enforced by `maxlength` and by the server
// (SurveysController#update_settings, Survey::MAX_NOTE) — this controller only
// tells the truth about it.
export default class extends Controller {
  static targets = [ "input", "count", "hint" ]
  static values  = { recommended: Number, max: Number }

  connect() {
    this.update()
  }

  update() {
    const n   = this.inputTarget.value.length
    const rec = this.recommendedValue
    const max = this.maxValue

    this.countTarget.textContent = t("editor.note_limit_count", { n: n, recommended: rec, max: max })
    // Two hot states, borrowed from the option-label counter: `is-over` is a
    // line crossed (still saveable, just cramped), `is-full` is a wall — the
    // field will not take another character.
    this.countTarget.classList.toggle("is-over", n > rec && n < max)
    this.countTarget.classList.toggle("is-full", n >= max)
    if (this.hasHintTarget) this.hintTarget.hidden = n <= rec
  }
}
