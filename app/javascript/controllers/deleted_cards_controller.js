import { Controller } from "@hotwired/stimulus"

// "Recently deleted" — puts a removed card back into the deck.
//
// The server renders the card (surveys#restore_card) rather than the client
// rebuilding it, for the same reason every other insertion path does: there is
// no render-from-JSON on this side, the editor's source of truth is the DOM, and
// card markup is only ever minted by surveys/_card_row.
//
// Nothing is persisted here. The splice marks the editor dirty and the ordinary
// autosave stores the deck with the card back in it — which is also what takes it
// out of the bin (Survey.record_deleted_cards).
export default class extends Controller {
  static values = { url: String }

  async restore(event) {
    const btn = event.currentTarget
    const cid = btn.dataset.restoreCid
    if (!cid || btn.disabled) return

    const editor = this._editor()
    if (!editor || editor.liveValue) return

    const resting = btn.textContent
    btn.disabled = true
    btn.textContent = "Restoring…"
    try {
      const res = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ cid })
      })
      const json = await res.json()
      if (!json || !json.ok) throw new Error((json && json.error) || "Couldn't restore that card")

      const card = editor.spliceRestoredCard(json.html, json.card)
      if (!card) throw new Error("Couldn't place that card")

      // Gone from the bin as far as this page is concerned — the save that
      // follows is what makes that true on the server too.
      btn.closest(".deleted-card-row")?.remove()
      if (!this.element.querySelector(".deleted-card-row")) this.element.remove()
      card.scrollIntoView({ behavior: "smooth", block: "center" })
    } catch (err) {
      btn.disabled = false
      btn.textContent = resting
      editor.flash?.(err.message, "text-hot-pink")
    }
  }

  _editor() {
    const root = document.querySelector("[data-controller~='survey-editor']")
    return root && this.application.getControllerForElementAndIdentifier(root, "survey-editor")
  }
}
