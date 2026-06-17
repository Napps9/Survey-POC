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
    "typeView", "scoreView", "publishView", "designView",
    "tabs", "typeTab", "scoreTab"
  ]

  open() { this._show("publishView") }
  openDesign() { this._show("designView") }
  close() { this._show("typeView") }
  showType() { this._show("typeView") }
  showScore() { this._show("scoreView") }

  _show(which) {
    const views = {
      typeView: this.hasTypeViewTarget ? this.typeViewTarget : null,
      scoreView: this.hasScoreViewTarget ? this.scoreViewTarget : null,
      publishView: this.hasPublishViewTarget ? this.publishViewTarget : null,
      designView: this.hasDesignViewTarget ? this.designViewTarget : null
    }
    Object.entries(views).forEach(([name, el]) => {
      if (el) el.classList.toggle("hidden", name !== which)
    })

    // The tab strip only belongs to the two peer views; the Publish/Design
    // overlays take over the whole column.
    const tabbed = which === "typeView" || which === "scoreView"
    if (this.hasTabsTarget) this.tabsTarget.classList.toggle("hidden", !tabbed)
    if (this.hasTypeTabTarget)  this.typeTabTarget.classList.toggle("is-active", which === "typeView")
    if (this.hasScoreTabTarget) this.scoreTabTarget.classList.toggle("is-active", which === "scoreView")
  }
}
