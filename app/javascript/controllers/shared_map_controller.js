import { Controller } from "@hotwired/stimulus"

// Read-only country tinting for the public shared-results page. A trimmed
// cousin of results_compare_controller.js's _paintMap: no click-to-compare
// (there's no compare panel here — a fixed org-scoped survey_results_compare
// URL wouldn't resolve for an anonymous viewer anyway), just colour by
// response count and a hover tooltip, off the same #results-region-map-data
// JSON contract the owner's page renders.
export default class extends Controller {
  connect() {
    const svg = this.element.querySelector(".world-map")
    const dataEl = document.getElementById("results-region-map-data")
    if (!svg || !dataEl) return

    let mapData
    try { mapData = JSON.parse(dataEl.textContent) } catch (_e) { return }

    const max = Math.max(1, ...Object.values(mapData).map(d => d.count))
    Object.entries(mapData).forEach(([ cc, d ]) => {
      const el = svg.querySelector("#" + cc)
      if (!el) return
      const paths = el.tagName.toLowerCase() === "g" ? el.querySelectorAll("path") : [ el ]
      const alpha = d.count === 0 ? 0.14 : 0.18 + 0.72 * (d.count / max)
      paths.forEach(p => { p.style.fill = `rgba(1,234,203,${alpha.toFixed(2)})` })

      if (d.count > 0) {
        const tip = document.createElementNS("http://www.w3.org/2000/svg", "title")
        tip.textContent = `${d.name}: ${d.count}`
        el.appendChild(tip)
      }
    })
  }
}
