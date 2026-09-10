// The NPS "liquid container" vessels, drawn client-side.
//
// Lifted out of type_panel_controller.js when a SECOND caller appeared: the
// editor's own animation picker (survey-editor#setNpsShape) swaps a card's
// vessel live, exactly as the type panel draws one when a card is switched TO
// NPS. Two controllers needed the same drawing, and a controller is not a
// place to import a controller from.
//
// Still a mirror of nps_helper.rb — Ruby renders these server-side and this
// file redraws them without a round-trip. Keep the two in sync;
// test/lib/nps_vessel_parity_test.rb fails the build when they drift.

// Mirror of nps_helper.rb's NPS_VESSELS: each themed container is a real
// object silhouette with its own width. [w, cx, hw, kind, top, bottom, path] —
// see the Ruby constant for the field meanings. Keep the two in sync;
// test/lib/nps_vessel_parity_test.rb fails the build when they drift.
export const NPS_VESSELS = {
  tube:     { w: 68,  cx: 34, hw: 11, kind: null, top: 16, bottom: 314,  path: "M20,16 L20,300 A14,14 0 0 0 48,300 L48,16" },
  pill:     { w: 78,  cx: 39, hw: 13, kind: null, top: 24, bottom: 316,  path: "M24,54 Q24,24 39,24 Q54,24 54,54 L54,286 Q54,316 39,316 Q24,316 24,286 Z" },
  can:      { w: 92,  cx: 46, hw: 26, kind: null, top: 36, bottom: 304,  path: "M16,52 Q16,36 46,36 Q76,36 76,52 L76,288 Q76,304 46,304 Q16,304 16,288 Z" },
  bottle:   { w: 96,  cx: 48, hw: 22, kind: null, top: 18, bottom: 306,  path: "M40,18 L40,74 Q24,94 24,134 L24,296 Q24,306 32,306 L64,306 Q72,306 72,296 L72,134 Q72,94 56,74 L56,18" },
  popsicle: { w: 98,  cx: 49, hw: 26, kind: "pop", top: 26, bottom: 268, path: "M20,54 Q20,26 49,26 Q78,26 78,54 L78,258 Q78,268 68,268 L30,268 Q20,268 20,258 Z" },
  glass:    { w: 106, cx: 53, hw: 28, kind: null, top: 24, bottom: 306,  path: "M18,24 L30,300 Q30,306 36,306 L70,306 Q76,306 76,300 L88,24" },
  beaker:   { w: 116, cx: 58, hw: 38, kind: null, top: 44, bottom: 306,  path: "M18,44 L18,298 Q18,306 26,306 L90,306 Q98,306 98,298 L98,52 L110,40" },
  jar:      { w: 118, cx: 59, hw: 40, kind: "jar", top: 50, bottom: 306, path: "M18,64 L18,298 Q18,306 26,306 L92,306 Q100,306 100,298 L100,64 L94,50 L24,50 Z" },
  flask:    { w: 130, cx: 65, hw: 22, kind: null, top: 22, bottom: 306,  path: "M54,22 L58,34 L58,90 L10,296 Q10,306 20,306 L110,306 Q120,306 120,296 L72,90 L72,34 L76,22" },
  mug:      { w: 132, cx: 54, hw: 34, kind: "mug", top: 52, bottom: 308, path: "M16,52 L16,300 Q16,308 24,308 L84,308 Q92,308 92,300 L92,52" },
}

// Mirrors NpsHelper::VESSEL_H / WIDTH_SCALE / STROKE_W.
export const VESSEL_H    = 340
export const WIDTH_SCALE = 2
export const STROKE_W    = 3

const NPS_EXTRAS = {
  jar: `<rect x="22" y="22" width="74" height="26" rx="8" fill="#dfe2ee" stroke="#1a1a1a" stroke-width="${STROKE_W}" vector-effect="non-scaling-stroke"/>`,
  mug: `<path d="M92,116 C130,120 130,244 92,248" fill="none" stroke="#1a1a1a" stroke-width="${Math.round(STROKE_W * 2.2)}" stroke-linecap="round" vector-effect="non-scaling-stroke"/>`,
  pop: `<rect x="41" y="260" width="16" height="52" rx="6" fill="#c9a678" stroke="#1a1a1a" stroke-width="${(STROKE_W * 0.7).toFixed(1)}" vector-effect="non-scaling-stroke"/>`,
}

function npsBubbles(cx, hw) {
  const rnd = (a, b) => a + Math.random() * (b - a)
  let s = ""
  for (let k = 0; k < 9; k++) {
    const x = rnd(cx - hw * 0.6, cx + hw * 0.6)
    const r = rnd(1.8, 4)
    const start = rnd(150, 235)
    const rise = -(start - rnd(10, 18))
    s += `<circle cx="${x.toFixed(1)}" cy="${start | 0}" r="${r.toFixed(1)}" fill="#ecfffb" class="nps-bub"
      style="--rise:${rise | 0}px;--sway:${rnd(-4, 4).toFixed(1)}px;--dur:${rnd(1.9, 3.4).toFixed(2)}s;--d:${rnd(0, 2.6).toFixed(2)}s"/>`
  }
  return s
}

// Mirror of nps_helper.rb#nps_stage_style — the custom properties that tie the
// digits, the vessel and the liquid to one set of path-derived numbers.
export function npsStageStyle(v) {
  return [
    `--nps-aspect: ${v.w * WIDTH_SCALE} / ${VESSEL_H}`,
    `--nps-top: ${v.top}px`,
    `--nps-travel: ${v.bottom - v.top}px`,
    `--nps-top-f: ${(v.top / VESSEL_H).toFixed(4)}`,
    `--nps-bot-f: ${((VESSEL_H - v.bottom) / VESSEL_H).toFixed(4)}`,
  ].join("; ")
}

// The SVG vessel — mirror of nps_helper.rb#nps_vessel_svg.
export function npsVesselSvg(shape, v) {
  const wave = y => `M-40,${y} q32.5,-8 65,0 t65,0 t65,0 t65,0 t65,0 L290,430 L-40,430 Z`
  return `
    <svg class="nps-vessel" viewBox="0 0 ${v.w * WIDTH_SCALE} ${VESSEL_H}" preserveAspectRatio="xMidYMid meet" aria-hidden="true" focusable="false">
      <defs>
        <linearGradient id="nps-g-${shape}" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" style="stop-color: var(--brand-primary, #16e0c4)"/>
          <stop offset="1" style="stop-color: var(--brand-primary, #01c9ad); stop-opacity: .85"/>
        </linearGradient>
        <clipPath id="nps-c-${shape}"><path d="${v.path} Z"/></clipPath>
      </defs>
      <g transform="scale(${WIDTH_SCALE} 1)">
        <g clip-path="url(#nps-c-${shape})">
          <rect x="-40" y="0" width="${v.w + 80}" height="${VESSEL_H}" fill="#eef0f6"/>
          <g class="nps-liquid">
            <g class="nps-surface">
              <path class="nps-wave2" d="${wave(3)}" fill="url(#nps-g-${shape})"/>
              <path class="nps-wave"  d="${wave(0)}" fill="url(#nps-g-${shape})"/>
            </g>
            <rect x="-40" y="4" width="${v.w + 80}" height="440" fill="url(#nps-g-${shape})"/>
            ${npsBubbles(v.cx, v.hw)}
          </g>
        </g>
        <path d="${v.path}" fill="none" stroke="#1a1a1a" stroke-width="${STROKE_W}" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>
        ${v.kind ? NPS_EXTRAS[v.kind] : ""}
      </g>
    </svg>`
}

// The vessel a shape name resolves to, with the same fallback the Ruby helper
// applies (NpsHelper#nps_vessel_for) so an unknown or missing name draws the
// default rather than nothing.
export function npsVesselFor(shape) {
  return NPS_VESSELS[shape] ? shape : "pill"
}
