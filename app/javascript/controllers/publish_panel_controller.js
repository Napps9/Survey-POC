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
    "typeView", "scoreView", "whyView", "publishView", "designView",
    "tabs", "typeTab", "scoreTab", "whyTab"
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
  showType() { this._show("typeView") }
  showScore() { this._show("scoreView") }
  showWhy() { this._show("whyView") }

  _show(which) {
    const views = {
      typeView: this.hasTypeViewTarget ? this.typeViewTarget : null,
      scoreView: this.hasScoreViewTarget ? this.scoreViewTarget : null,
      whyView: this.hasWhyViewTarget ? this.whyViewTarget : null,
      publishView: this.hasPublishViewTarget ? this.publishViewTarget : null,
      designView: this.hasDesignViewTarget ? this.designViewTarget : null
    }
    Object.entries(views).forEach(([name, el]) => {
      if (el) el.classList.toggle("hidden", name !== which)
    })

    // The tab strip belongs to the three peer views; the Publish/Design
    // overlays take over the whole column.
    const tabbed = which === "typeView" || which === "scoreView" || which === "whyView"
    if (this.hasTabsTarget) this.tabsTarget.classList.toggle("hidden", !tabbed)
    if (this.hasTypeTabTarget)  this.typeTabTarget.classList.toggle("is-active", which === "typeView")
    if (this.hasScoreTabTarget) this.scoreTabTarget.classList.toggle("is-active", which === "scoreView")
    if (this.hasWhyTabTarget)   this.whyTabTarget.classList.toggle("is-active", which === "whyView")
  }
}
