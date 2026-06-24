import { Controller } from "@hotwired/stimulus"

// Copies text to the clipboard and briefly swaps the trigger's label (and,
// optionally, its colour). A CSP-friendly replacement for inline
// onclick="navigator.clipboard.writeText(...)" handlers.
//
// Copy a sibling input's value (controller on a wrapper):
//   <div data-controller="clipboard"
//        data-clipboard-copied-label-value="Copied!" data-clipboard-label-value="Copy">
//     <input data-clipboard-target="source" value="https://…">
//     <button data-action="clipboard#copy">Copy</button>
//   </div>
//
// Copy a literal value (controller on the button itself):
//   <button data-controller="clipboard" data-clipboard-text-value="https://…"
//           data-action="clipboard#copy">Copy</button>
export default class extends Controller {
  static targets = ["source"]
  static values = {
    text: String,
    copiedLabel: { type: String, default: "Copied!" },
    label: String,
    copiedColor: String,
    restore: { type: Number, default: 2000 }
  }

  copy(event) {
    const btn = event.currentTarget
    const text = this.hasTextValue && this.textValue.length
      ? this.textValue
      : (this.hasSourceTarget ? this.sourceTarget.value : "")
    if (!navigator.clipboard || !navigator.clipboard.writeText) return

    navigator.clipboard.writeText(text).then(() => {
      const prevLabel = this.hasLabelValue ? this.labelValue : btn.textContent
      const prevColor = btn.style.color
      btn.textContent = this.copiedLabelValue
      if (this.hasCopiedColorValue) btn.style.color = this.copiedColorValue
      setTimeout(() => {
        btn.textContent = prevLabel
        if (this.hasCopiedColorValue) btn.style.color = prevColor
      }, this.restoreValue)
    }).catch(() => {})
  }
}
