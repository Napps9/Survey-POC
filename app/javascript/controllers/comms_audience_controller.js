import { Controller } from "@hotwired/stimulus"

// The campaign's audience panel: builds the audience definition from its
// inputs, PATCHes it as its own slice (the brand-palette shape — a small
// partial PATCH against the campaign's only-touch-present-keys endpoint) and
// keeps the live recipient count fresh. The count comes from the same
// resolver the send path uses, so the number shown is the number mailed.
export default class extends Controller {
  static targets = ["kind", "section", "orgSelect", "roleSelect", "emailsInput", "listSelect", "count"]
  static values = { url: String, countUrl: String, definition: Object }

  connect() {
    this._seed()
    this._toggleSections()
    this._fetchCount()
  }

  disconnect() {
    clearTimeout(this._timer)
  }

  changed() {
    this._toggleSections()
    clearTimeout(this._timer)
    this._timer = setTimeout(() => this._persist(), 600)
  }

  definition() {
    const kind = this.kindTargets.find((r) => r.checked)?.value || "all_users"
    switch (kind) {
      case "organisations":
        return {
          kind,
          organisation_ids: Array.from(this.orgSelectTarget.selectedOptions).map((o) => parseInt(o.value, 10)),
          role: this.roleSelectTarget.value
        }
      case "users":
        return {
          kind,
          emails: this.emailsInputTarget.value.split(/[\s,]+/).map((e) => e.trim()).filter(Boolean)
        }
      case "list":
        return { kind, list_id: parseInt(this.listSelectTarget.value, 10) || null }
      default:
        return { kind: "all_users" }
    }
  }

  async _persist() {
    if (!this.urlValue) return
    try {
      await fetch(this.urlValue, {
        method: "PATCH", headers: this._headers(),
        body: JSON.stringify({ audience: this.definition() })
      })
    } catch (_) { /* the count fetch below will still reflect the inputs */ }
    this._fetchCount()
  }

  async _fetchCount() {
    if (!this.hasCountTarget || !this.countUrlValue) return
    this.countTarget.textContent = "…"
    try {
      const res = await fetch(this.countUrlValue, {
        method: "POST", headers: this._headers(),
        body: JSON.stringify({ audience: this.definition() })
      })
      const json = await res.json()
      this.countTarget.textContent = json.ok ? json.count : "?"
    } catch (_) {
      this.countTarget.textContent = "?"
    }
  }

  _toggleSections() {
    const kind = this.kindTargets.find((r) => r.checked)?.value || "all_users"
    this.sectionTargets.forEach((s) => { s.hidden = s.dataset.audienceSection !== kind })
  }

  _seed() {
    const def = this.definitionValue || {}
    const kind = def.kind || "all_users"
    this.kindTargets.forEach((r) => { r.checked = r.value === kind })
    if (Array.isArray(def.organisation_ids) && this.hasOrgSelectTarget) {
      const wanted = def.organisation_ids.map(String)
      Array.from(this.orgSelectTarget.options).forEach((o) => { o.selected = wanted.includes(o.value) })
    }
    if (def.role && this.hasRoleSelectTarget) this.roleSelectTarget.value = def.role
    if (Array.isArray(def.emails) && this.hasEmailsInputTarget) this.emailsInputTarget.value = def.emails.join("\n")
    if (def.list_id && this.hasListSelectTarget) this.listSelectTarget.value = String(def.list_id)
  }

  _headers() {
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
    }
  }
}
