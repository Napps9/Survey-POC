import { Controller } from "@hotwired/stimulus"

// Manages the token-type rows in the Tokenisation settings panel (add /
// remove / rename), then serializes them into a hidden `token_types` field
// right before the settings form submits — same one-form-per-setting, plain
// POST pattern the rest of the publish panel uses, just with a JS-built list
// instead of a single field. The tokenisation-enabled checkbox routes through
// `save` too (rather than submitting the form directly), so toggling it never
// silently drops an in-progress add/rename that hasn't been saved yet.
export default class extends Controller {
  static targets = ["list", "row", "field"]

  addRow(event) {
    event.preventDefault()
    const row = document.createElement("div")
    row.className = "token-type-row"
    row.dataset.tokenTypesTarget = "row"
    row.style.cssText = "display:flex;gap:6px;align-items:center;"
    row.innerHTML = `
      <input type="text" data-token-types-target="icon" maxlength="8" value="⭐"
             style="width:40px;text-align:center;padding:7px 4px;border-radius:8px;background:rgba(255,255,255,0.07);border:1px solid rgba(255,255,255,0.15);color:#fff;font-size:16px;outline:none;" />
      <input type="text" data-token-types-target="name" maxlength="40" placeholder="e.g. Gold Coins"
             style="flex:1;min-width:0;padding:7px 10px;border-radius:8px;background:rgba(255,255,255,0.07);border:1px solid rgba(255,255,255,0.15);color:#fff;font-family:'ABeeZee',sans-serif;font-size:13px;outline:none;" />
      <button type="button" data-action="click->token-types#removeRow"
              style="flex-shrink:0;width:26px;height:26px;border-radius:8px;background:transparent;border:1px solid rgba(255,255,255,0.15);color:rgba(255,255,255,0.6);cursor:pointer;">×</button>
    `
    this.listTarget.appendChild(row)
    row.querySelector('[data-token-types-target="name"]').focus()
  }

  removeRow(event) {
    event.preventDefault()
    event.currentTarget.closest('[data-token-types-target="row"]')?.remove()
  }

  // Serialize the current rows into the hidden field, then submit.
  save(event) {
    if (event.cancelable) event.preventDefault()
    this._sync()
    event.target.closest("form")?.requestSubmit()
  }

  _sync() {
    if (!this.hasFieldTarget) return
    const types = this.rowTargets.map(row => {
      let id = row.dataset.tokenId
      if (!id) {
        id = (typeof crypto !== "undefined" && crypto.randomUUID)
          ? crypto.randomUUID().slice(0, 8)
          : Math.random().toString(36).slice(2, 10)
        row.dataset.tokenId = id
      }
      const name = row.querySelector('[data-token-types-target="name"]')?.value.trim() || ""
      const icon = row.querySelector('[data-token-types-target="icon"]')?.value.trim() || ""
      return { id, name, icon }
    }).filter(t => t.name)
    this.fieldTarget.value = JSON.stringify(types)
  }
}
