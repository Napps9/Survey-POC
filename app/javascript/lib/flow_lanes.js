// Derived branch "lanes" — the wiring-inferred grouping that predates
// first-class flows. A lane starts at a branch entry (the target of an answer
// route) and its members are the cards that entry DOMINATES: every path from
// the deck start to them passes through the entry. Dominators (vs a simple
// in-degree walk) keep a parent lane intact past the point where a sub-branch
// rejoins it, and make nested sub-branches fall out as smaller lanes.
//
// Extracted from logic_map_controller so the map (legacy-deck rendering) and
// the Flows panel (per-lane "convert to flow") share one implementation.
// First-class flows supersede this: the map builds lanes from stored flow
// data first and only derives lanes over cards no flow claims.

// Mirrors Survey::FLOW_COLORS — the palette stored flows are minted from, so
// derived-lane colours and flow colours come from one family.
export const LANE_PALETTE = [ "#8B85FF", "#01EACB", "#F59E0B", "#F472B6", "#38BDF8", "#A3E635" ]

// A card's main continuation as an encoded target ("card:<cid>" | "end:<id>"):
// its answer-logic default, else its `next`, else the linear next card, else
// the finish. (Answer routes are NOT continuations — they open sub-branches.)
export function contTarget(card, cards) {
  if (!card) return ""
  const d = card.logic && card.logic.default
  if (d && d.card) return `card:${d.card}`
  if (d && d.end) return `end:${d.end}`
  if (card.next && card.next.card) return `card:${card.next.card}`
  if (card.next && card.next.end) return `end:${card.next.end}`
  const i = cards.findIndex(c => c.cid === card.cid)
  return (i >= 0 && i + 1 < cards.length && cards[i + 1].cid) ? `card:${cards[i + 1].cid}` : "end:default"
}

export function contCid(card, cards) {
  const t = contTarget(card, cards)
  return t.startsWith("card:") ? t.slice(5) : null
}

// The derived lanes for a deck. Each carries its entry, label, colour, member
// set, inbound route, the main continuation `spine` (entry → continuation → …
// up to the rejoin), the encoded `rejoin` target, and `simple` (spine covers
// every member ⇒ a plain chain safe to reorder / convert to a flow).
export function computeLanes(cards) {
  const cids = cards.map(c => c.cid).filter(Boolean)
  if (!cids.length) return []
  const byCid = new Map(cards.map(c => [ c.cid, c ]))
  const start = cids[0]

  const adj = new Map(cids.map(c => [ c, [] ]))
  const link = (from, to) => { if (byCid.has(to) && adj.has(from)) adj.get(from).push(to) }
  cards.forEach((c, i) => {
    let covered = false
    const L = c.logic
    if (L && Array.isArray(L.routes)) L.routes.forEach(r => { if (r && r.to && r.to.card) link(c.cid, r.to.card) })
    if (L && L.default && (L.default.card || L.default.end)) { covered = true; if (L.default.card) link(c.cid, L.default.card) }
    if (!covered && c.next && (c.next.card || c.next.end)) { covered = true; if (c.next.card) link(c.cid, c.next.card) }
    if (!covered && i + 1 < cards.length && cards[i + 1].cid) link(c.cid, cards[i + 1].cid)
  })
  const reach = (skip) => {
    const seen = new Set(), stack = [ start ]
    while (stack.length) {
      const x = stack.pop()
      if (x === skip || seen.has(x) || !adj.has(x)) continue
      seen.add(x)
      adj.get(x).forEach(y => { if (y !== skip) stack.push(y) })
    }
    return seen
  }
  const reach0 = reach(null)

  const lanes = []
  const seenEntry = new Set()
  cards.forEach(c => {
    if (!c.logic || !Array.isArray(c.logic.routes)) return
    c.logic.routes.forEach(r => {
      const E = r && r.to && r.to.card
      if (!E || !byCid.has(E) || !reach0.has(E) || seenEntry.has(E)) return
      seenEntry.add(E)
      const without = reach(E)
      const members = new Set([ ...reach0 ].filter(x => x === E || !without.has(x)))
      const label = (byCid.get(E).lane_label || (r.match && r.match.value) || "Branch").toString()
      lanes.push({ entry: E, label, members, inbound: { cid: c.cid, answer: (r.match && r.match.value) || "" } })
    })
  })
  lanes.forEach((l, i) => {
    l.color = LANE_PALETTE[i % LANE_PALETTE.length]
    const spine = [], seen = new Set()
    let cur = l.entry
    while (cur && l.members.has(cur) && !seen.has(cur)) {
      seen.add(cur)
      spine.push(cur)
      cur = contCid(byCid.get(cur), cards)
    }
    l.spine = spine
    l.rejoin = spine.length ? contTarget(byCid.get(spine[spine.length - 1]), cards) : ""
    l.simple = spine.length === l.members.size
  })
  return lanes
}
