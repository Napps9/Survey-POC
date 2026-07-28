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
    "typeView", "whyView", "branchView", "quizView", "tokensView",
    "publishView", "designView",
    "tabs", "typeTab", "whyTab", "branchTab", "quizTab", "tokensTab"
  ]

  connect() {
    // The settings toggles (results-comparison, form mode, custom link in the
    // Publish panel; quiz / logic / tokenisation in their feature tabs) submit
    // as plain full-page POSTs — see SurveysController#update_settings — so
    // the panel would otherwise silently reset to the answer-type tab on
    // every toggle. The redirect echoes back panel=publish or tab=<feature>
    // so we can reopen the right view (editor-panel reads the same params to
    // un-collapse the column; URL cleanup waits a frame so it isn't raced).
    const params = new URLSearchParams(window.location.search)
    const tabViews = { quiz: "quizView", tokens: "tokensView", logic: "branchView" }
    const returnedTab = tabViews[params.get("tab")]
    if (params.get("panel") === "publish") {
      this.open()
    } else if (returnedTab) {
      this._show(returnedTab)
    }
    if (params.get("panel") === "publish" || returnedTab) {
      requestAnimationFrame(() => {
        params.delete("panel")
        params.delete("tab")
        const query = params.toString()
        const url = window.location.pathname + (query ? `?${query}` : "") + window.location.hash
        window.history.replaceState(window.history.state, "", url)
      })
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
  showWhy() { this._show("whyView") }
  showBranch() { this._show("branchView") }
  showQuizTab() { this._show("quizView") }
  showTokensTab() { this._show("tokensView") }

  _show(which) {
    const views = {
      typeView: this.hasTypeViewTarget ? this.typeViewTarget : null,
      whyView: this.hasWhyViewTarget ? this.whyViewTarget : null,
      branchView: this.hasBranchViewTarget ? this.branchViewTarget : null,
      quizView: this.hasQuizViewTarget ? this.quizViewTarget : null,
      tokensView: this.hasTokensViewTarget ? this.tokensViewTarget : null,
      publishView: this.hasPublishViewTarget ? this.publishViewTarget : null,
      designView: this.hasDesignViewTarget ? this.designViewTarget : null
    }
    Object.entries(views).forEach(([name, el]) => {
      if (el) el.classList.toggle("hidden", name !== which)
    })

    // The tab strip belongs to the peer views (answer types / quiz / tokens /
    // logic / why); the Publish/Design overlays take over the column.
    const tabbed = ["typeView", "whyView", "branchView", "quizView", "tokensView"].includes(which)
    if (this.hasTabsTarget) this.tabsTarget.classList.toggle("hidden", !tabbed)
    const setTab = (has, el, view) => {
      if (!has) return
      const active = which === view
      el.classList.toggle("is-active", active)
      // Mirror the visual state for assistive tech (the tabs carry role=tab).
      if (el.getAttribute("role") === "tab") el.setAttribute("aria-selected", active)
    }
    setTab(this.hasTypeTabTarget, this.hasTypeTabTarget && this.typeTabTarget, "typeView")
    setTab(this.hasWhyTabTarget, this.hasWhyTabTarget && this.whyTabTarget, "whyView")
    setTab(this.hasBranchTabTarget, this.hasBranchTabTarget && this.branchTabTarget, "branchView")
    setTab(this.hasQuizTabTarget, this.hasQuizTabTarget && this.quizTabTarget, "quizView")
    setTab(this.hasTokensTabTarget, this.hasTokensTabTarget && this.tokensTabTarget, "tokensView")
  }
}
