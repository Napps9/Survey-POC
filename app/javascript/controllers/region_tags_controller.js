import { Controller } from "@hotwired/stimulus"

// Wizard-side region tags: each added region becomes a removable chip whose
// hidden inputs (region_tags[][country_code] / region_tags[][label]) submit
// with the create form. The editor's publish panel manages them afterwards.
export default class extends Controller {
  static targets = ["country", "label", "list", "count"]

  add(e) {
    e.preventDefault()
    const code = this.countryTarget.value
    if (!code) return
    const name  = this.countryTarget.selectedOptions[0]?.dataset.name || code
    const label = this.labelTarget.value.trim()
    const key   = `${code}|${label}`
    if (!this.listTarget.querySelector(`[data-key="${CSS.escape(key)}"]`)) {
      this.listTarget.appendChild(this._chip(key, code, name, label))
    }
    this.labelTarget.value = ""
    this._refreshCount()
  }

  // Chip total shown on the collapsed "Region settings" CTA, so picked
  // regions stay visible even when the disclosure is closed.
  _refreshCount() {
    if (!this.hasCountTarget) return
    const n = this.listTarget.children.length
    this.countTarget.textContent = n
    this.countTarget.style.display = n ? "inline-flex" : "none"
  }

  _chip(key, code, name, label) {
    const chip = document.createElement("span")
    chip.dataset.key = key
    chip.style.cssText = "display:inline-flex;align-items:center;gap:8px;padding:8px 12px;border-radius:100px;background:rgba(1,234,203,0.08);border:1.5px solid #01EACB;font-family:'ABeeZee',sans-serif;font-size:13px;color:#1C2034;"

    const text = document.createElement("span")
    text.textContent = label ? `🌍 ${name} · ${label}` : `🌍 ${name}`

    const remove = document.createElement("button")
    remove.type = "button"
    remove.setAttribute("aria-label", "Remove")
    remove.textContent = "✕"
    remove.style.cssText = "background:none;border:none;cursor:pointer;color:rgba(0,0,0,0.45);font-size:12px;padding:0;line-height:1;"
    remove.addEventListener("click", () => { chip.remove(); this._refreshCount() })

    const country = document.createElement("input")
    country.type = "hidden"; country.name = "region_tags[][country_code]"; country.value = code
    const lbl = document.createElement("input")
    lbl.type = "hidden"; lbl.name = "region_tags[][label]"; lbl.value = label

    chip.append(text, remove, country, lbl)
    return chip
  }
}
