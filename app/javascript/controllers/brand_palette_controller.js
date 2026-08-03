import { Controller } from "@hotwired/stimulus"
import { DEFAULT, resolve, applyVars, clearVars, isDefault, validHex } from "lib/brand_palette"

// Drives the brand-colour pickers in two places:
//  - the Create wizard's "Brand colours" step (live mock, palette submitted
//    with the form — no url value, so no autosave)
//  - the Verto editor's publish panel (live-applies to the card canvas +
//    preview overlay and autosaves THIS survey's palette via PATCH)
export default class extends Controller {
  static targets = ["colorInput", "hexInput", "preview", "status"]
  static values = { url: String }

  connect() {
    this._lastBg = this._roleValue("bg")
    this._apply()
  }

  onColor(event) {
    const role = event.target.dataset.brandRole
    const hexInput = this._for(this.hexInputTargets, role)
    if (hexInput) hexInput.value = event.target.value.toUpperCase()
    if (role === "bg") this._panelFollowsBg()
    this._apply()
    this._save()
  }

  onHex(event) {
    const role = event.target.dataset.brandRole
    let value = event.target.value.trim()
    if (!validHex(value)) return
    if (!value.startsWith("#")) value = "#" + value
    const colorInput = this._for(this.colorInputTargets, role)
    if (colorInput) colorInput.value = value.toLowerCase()
    if (role === "bg") this._panelFollowsBg()
    this._apply()
    this._save()
  }

  // The panel swatch tracks the background until the user picks a distinct
  // panel colour: an untouched panel (still equal to the previous background,
  // or to the legacy default) repainting itself to an old hex on every
  // background change is exactly the "panel doesn't match what I picked"
  // complaint that made panel a role.
  _panelFollowsBg() {
    const newBg = this._roleValue("bg")
    const panel = this._roleValue("panel")
    if (panel && (panel === this._lastBg || panel === DEFAULT.panel.toLowerCase())) {
      const colorInput = this._for(this.colorInputTargets, "panel")
      if (colorInput) colorInput.value = newBg
      const hexInput = this._for(this.hexInputTargets, "panel")
      if (hexInput) hexInput.value = newBg.toUpperCase()
    }
    this._lastBg = newBg
  }

  _roleValue(role) {
    return (this._for(this.colorInputTargets, role)?.value || "").toLowerCase()
  }

  _for(targets, role) {
    return targets.find((el) => el.dataset.brandRole === role)
  }

  _palette() {
    const p = {}
    this.colorInputTargets.forEach((el) => {
      p[el.dataset.brandRole] = el.value
    })
    return p
  }

  _apply() {
    const raw = this._palette()
    const resolved = resolve(raw)
    const blank = isDefault(raw)
    this.previewTargets.forEach((el) => (blank ? clearVars(el) : applyVars(el, resolved)))
  }

  _save() {
    if (!this.hasUrlValue) return
    clearTimeout(this._timer)
    this._status("Saving…")
    this._timer = setTimeout(() => this._patch(), 500)
  }

  async _patch() {
    try {
      const res = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({ brand_palette: this._palette() }),
      })
      const data = await res.json()
      this._status(data.ok ? "Saved" : "Couldn't save")
    } catch (_e) {
      this._status("Couldn't save")
    }
  }

  _status(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }
}
