import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// Manages the extra branch end-screen rows in the publish panel (add / edit /
// remove), then serializes them into a hidden `end_screens` field right before
// the settings form submits — the same one-form-per-setting POST pattern the
// rest of the panel uses, mirroring token_types_controller. The built-in
// "default" thank-you screen is edited separately (legacy columns) and is not
// listed here.
export default class extends Controller {
  static targets = ["list", "row", "field"]

  addRow(event) {
    event.preventDefault()
    const row = document.createElement("div")
    row.className = "end-screen-row"
    row.dataset.endScreensTarget = "row"
    row.style.cssText = "display:flex;flex-direction:column;gap:6px;padding:10px;border-radius:12px;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.1);"
    const inp = "padding:7px 10px;border-radius:8px;background:rgba(255,255,255,0.07);border:1px solid rgba(255,255,255,0.15);color:#fff;font-family:'ABeeZee',sans-serif;font-size:13px;outline:none;"
    row.innerHTML = `
      <div style="display:flex;gap:6px;align-items:center;">
        <input type="text" data-end-screens-target="title" maxlength="80" placeholder="${t("editor.end_screens.title_placeholder").replace(/"/g, "&quot;")}"
               style="flex:1;min-width:0;${inp}" />
        <button type="button" data-action="click->end-screens#removeRow"
                style="flex-shrink:0;width:26px;height:26px;border-radius:8px;background:transparent;border:1px solid rgba(255,255,255,0.15);color:rgba(255,255,255,0.6);cursor:pointer;">×</button>
      </div>
      <textarea data-end-screens-target="body" maxlength="400" rows="2" placeholder="${t("editor.end_screens.body_placeholder").replace(/"/g, "&quot;")}"
                style="width:100%;box-sizing:border-box;resize:vertical;${inp}"></textarea>
      <input type="url" data-end-screens-target="forwardUrl" placeholder="${t("editor.end_screens.url_placeholder").replace(/"/g, "&quot;")}"
             style="width:100%;box-sizing:border-box;${inp}" />
      <input type="text" data-end-screens-target="forwardLabel" maxlength="40" placeholder="${t("editor.end_screens.button_placeholder").replace(/"/g, "&quot;")}"
             style="width:100%;box-sizing:border-box;${inp}" />
    `
    this.listTarget.appendChild(row)
    row.querySelector('[data-end-screens-target="title"]').focus()
  }

  removeRow(event) {
    event.preventDefault()
    event.currentTarget.closest('[data-end-screens-target="row"]')?.remove()
    this._sync()
  }

  // Serialize the current rows into the hidden field, then submit.
  save(event) {
    if (event.cancelable) event.preventDefault()
    this._sync()
    event.target.closest("form")?.requestSubmit()
  }

  _sync() {
    if (!this.hasFieldTarget) return
    const val = (row, name) => row.querySelector(`[data-end-screens-target="${name}"]`)?.value.trim() || ""
    const screens = this.rowTargets.map(row => {
      let id = row.dataset.endScreenId
      if (!id) {
        id = "es_" + ((typeof crypto !== "undefined" && crypto.randomUUID)
          ? crypto.randomUUID().slice(0, 8)
          : Math.random().toString(36).slice(2, 10))
        row.dataset.endScreenId = id
      }
      return {
        id,
        title: val(row, "title"),
        body: val(row, "body"),
        forward_url: val(row, "forwardUrl"),
        forward_label: val(row, "forwardLabel")
      }
    }).filter(s => s.title || s.body || s.forward_url)
    this.fieldTarget.value = JSON.stringify(screens)
  }
}
