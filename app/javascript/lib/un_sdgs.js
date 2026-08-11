// The 17 UN Sustainable Development Goals — titles and official brand colours.
//
// A mirror of UnSdgs (app/lib/un_sdgs.rb), which is the authority; this copy
// exists because the Ask Verto stream renders source cards client-side and a
// stamped source carries only the goal NUMBERS. Titles are the UN's own proper
// nouns, deliberately not translated (see UnSdgs), and the colours are fixed by
// the UN's brand guidelines. JsConstantParityTest asserts both maps match the
// Ruby side — do not edit one without the other.
export const SDG_TITLES = {
  1: "No Poverty",
  2: "Zero Hunger",
  3: "Good Health and Well-being",
  4: "Quality Education",
  5: "Gender Equality",
  6: "Clean Water and Sanitation",
  7: "Affordable and Clean Energy",
  8: "Decent Work and Economic Growth",
  9: "Industry, Innovation and Infrastructure",
  10: "Reduced Inequalities",
  11: "Sustainable Cities and Communities",
  12: "Responsible Consumption and Production",
  13: "Climate Action",
  14: "Life Below Water",
  15: "Life on Land",
  16: "Peace, Justice and Strong Institutions",
  17: "Partnerships for the Goals"
}

export const SDG_COLORS = {
  1: "#E5243B",
  2: "#DDA63A",
  3: "#4C9F38",
  4: "#C5192D",
  5: "#FF3A21",
  6: "#26BDE2",
  7: "#FCC30B",
  8: "#A21942",
  9: "#FD6925",
  10: "#DD1367",
  11: "#FD9D24",
  12: "#BF8B2E",
  13: "#3F7E44",
  14: "#0A97D9",
  15: "#56C02B",
  16: "#00689D",
  17: "#19486A"
}

// "SDG 13 · Climate Action" — the chip text. Falls back to the bare label so
// an out-of-range number (a corrupt snapshot) still renders something honest.
export function sdgChipText(n) {
  const title = SDG_TITLES[n]
  return title ? `SDG ${n} · ${title}` : `SDG ${n}`
}

export function sdgColor(n) {
  return SDG_COLORS[n] || "#8B85FF"
}
