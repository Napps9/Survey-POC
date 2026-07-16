import { Controller } from "@hotwired/stimulus"

// Toggles the right-hand column between four views: the answer-type picker,
// the Verto-score breakdown, the design panel (colours / background / logo)
// and the publish & share panel.
//
// Answer type ⇆ Verto score are peer tabs (the tab strip at the top of the
// column). Publish and Design are overlays opened from the bottom-bar CTAs;
// each has a back button that returns to the answer-type tab. The tab strip is
// hidden while an overlay is open.
export default class extends Controller {
  static targets = [
    "typeView", "scoreView", "whyView", "branchView", "publishView", "designView",
    "tabs", "typeTab", "scoreTab", "whyTab", "branchTab"
  ]

  connect() {
    // The Publish panel's settings toggles (results-comparison, quiz mode,
    // form mode, tokenisation, consent, thank-you, custom link) submit as
    // plain full-page POSTs — see SurveysController#update_settings — so the
    // panel would otherwise silently reset to the answer-type tab on every
    // toggle. The redirect echoes back panel=publish so we can reopen it.
    const params = new URLSearchParams(window.location.search)
    if (params.get("panel") === "publish") {
      this.open()
      params.delete("panel")
      const query = params.toString()
      const url = window.location.pathname + (query ? `?${query}` : "") + window.location.hash
      window.history.replaceState(window.history.state, "", url)
    }
  }

  open() { this._show("publishView") }
  openDesign() { this._show("designView") }
  close() { this._show("typeView") }

  // A card was clicked. Only drop back to the answer-type editor if a full-column
  // overlay (Publish / Design) is open, so clicking a card there reveals its edit
  // options. The peer tabs (Answer type / Why / Branching / Score) stay put —
  // selecting or editing a card shouldn't yank you off the tab you're working in.
  closeForCard() {
    const shown = (has, el) => has && !el.classList.contains("hidden")
    if (shown(this.hasPublishViewTarget, this.publishViewTarget) ||
        shown(this.hasDesignViewTarget, this.designViewTarget)) {
      this._show("typeView")
    }
  }
  showType() { this._show("typeView") }
  showScore() { this._show("scoreView") }
  showWhy() { this._show("whyView") }
  showBranch() { this._show("branchView") }

  _show(which) {
    const views = {
      typeView: this.hasTypeViewTarget ? this.typeViewTarget : null,
      scoreView: this.hasScoreViewTarget ? this.scoreViewTarget : null,
      whyView: this.hasWhyViewTarget ? this.whyViewTarget : null,
      branchView: this.hasBranchViewTarget ? this.branchViewTarget : null,
      publishView: this.hasPublishViewTarget ? this.publishViewTarget : null,
      designView: this.hasDesignViewTarget ? this.designViewTarget : null
    }
    Object.entries(views).forEach(([name, el]) => {
      if (el) el.classList.toggle("hidden", name !== which)
    })

    // The tab strip belongs to the peer views (answer type / why / branching /
    // score); the Publish/Design overlays take over the whole column.
    const tabbed = ["typeView", "scoreView", "whyView", "branchView"].includes(which)
    if (this.hasTabsTarget) this.tabsTarget.classList.toggle("hidden", !tabbed)
    if (this.hasTypeTabTarget)   this.typeTabTarget.classList.toggle("is-active", which === "typeView")
    if (this.hasScoreTabTarget)  this.scoreTabTarget.classList.toggle("is-active", which === "scoreView")
    if (this.hasWhyTabTarget)    this.whyTabTarget.classList.toggle("is-active", which === "whyView")
    if (this.hasBranchTabTarget) this.branchTabTarget.classList.toggle("is-active", which === "branchView")
  }
}
