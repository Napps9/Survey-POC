// Wiring warnings over the serialized deck + flows — the JS sibling of
// LogicGraph.validate (the Ruby oracle stays authoritative for runtime
// semantics; this mirror exists so the editor can SURFACE problems live,
// which the Ruby side never did). Extended with flow-level checks the Ruby
// validator predates: empty flows, unreachable flows, exit cycles.
//
// Everything here is advisory — all of these degrade safely at play time
// (dangling targets fall through linearly, cycles hit the hop budget) — so
// warnings never block a save.
//
// Returns [{ kind, num?, flowId?, flowIds? }] where kind is one of:
//   dangling          — card `num` has a route/default/next to a target
//                       that no longer exists
//   self_loop         — card `num` routes to itself
//   empty_flow        — flow `flowId` has no member cards
//   unreachable_flow  — no path from the first card reaches flow `flowId`
//   flow_cycle        — flows `flowIds` chain their exits back into a loop

export function computeWarnings(cards, flows, endIds) {
  const list = Array.isArray(cards) ? cards : []
  const flowList = Array.isArray(flows) ? flows : []
  const ends = new Set((endIds || []).map(String))
  const warnings = []

  const cidToIdx = new Map()
  list.forEach((c, i) => { if (c && c.cid) cidToIdx.set(c.cid, i) })

  const isEnd  = to => to && to.end != null && String(to.end) !== ""
  const isCard = to => to && to.card != null && String(to.card) !== ""
  const targetsOf = c => {
    const out = []
    const logic = (c && c.logic) || {}
    ;(Array.isArray(logic.routes) ? logic.routes : []).forEach(r => { if (r && r.to) out.push(r.to) })
    if (logic.default) out.push(logic.default)
    if (c && c.next) out.push(c.next)
    return out
  }

  // ── Dangling targets + self-loops (mirror of LogicGraph.validate) ──
  const danglingNums = new Set(), selfLoopNums = new Set()
  list.forEach((c, i) => {
    targetsOf(c).forEach(to => {
      if (isEnd(to)) {
        if (!ends.has(String(to.end))) danglingNums.add(i + 1)
      } else if (isCard(to)) {
        if (!cidToIdx.has(to.card)) danglingNums.add(i + 1)
        else if (c.cid && to.card === c.cid) selfLoopNums.add(i + 1)
      }
    })
  })
  danglingNums.forEach(num => warnings.push({ kind: "dangling", num }))
  selfLoopNums.forEach(num => warnings.push({ kind: "self_loop", num }))

  // ── Reachability from card 0 (mirror of LogicGraph.edges_from: answer
  // routes are extra edges; a RESOLVABLE default/next/end replaces the linear
  // edge, a dangling one leaves it — same as the runtime fail-safe) ──
  const reachable = new Set()
  const stack = list.length ? [ 0 ] : []
  while (stack.length) {
    const i = stack.pop()
    if (i == null || i < 0 || i >= list.length || reachable.has(i)) continue
    reachable.add(i)
    const c = list[i] || {}
    const logic = c.logic || {}
    let covered = false
    ;(Array.isArray(logic.routes) ? logic.routes : []).forEach(r => {
      if (r && isCard(r.to) && cidToIdx.has(r.to.card)) stack.push(cidToIdx.get(r.to.card))
    })
    ;[ logic.default, c.next ].forEach(to => {
      if (isEnd(to)) covered = true
      else if (isCard(to) && cidToIdx.has(to.card)) { stack.push(cidToIdx.get(to.card)); covered = true }
    })
    if (!covered && i + 1 < list.length) stack.push(i + 1)
  }

  // ── Flow-level checks ──
  const flowOf = new Map() // member cid -> flowId
  list.forEach(c => { if (c && c.flow_id && c.cid) flowOf.set(c.cid, c.flow_id) })

  flowList.forEach(f => {
    const entryIdx = list.findIndex(c => c && c.flow_id === f.id)
    if (entryIdx < 0) warnings.push({ kind: "empty_flow", flowId: f.id })
    else if (!reachable.has(entryIdx)) warnings.push({ kind: "unreachable_flow", flowId: f.id })
  })

  // Exit cycles: flow → flow edges from each exit ({flow} directly, or a
  // {card} exit landing on another flow's member). Answer routes between
  // flows are deliberate branching, not a wiring smell — only exits count.
  const flowEdges = new Map()
  flowList.forEach(f => {
    const ex = (f && f.exit) || {}
    let to = null
    if (ex.flow != null && String(ex.flow) !== "") to = String(ex.flow)
    else if (isCard(ex) && flowOf.has(ex.card)) to = flowOf.get(ex.card)
    if (to && to !== f.id) flowEdges.set(f.id, to)
  })
  const inReported = new Set()
  flowList.forEach(f => {
    if (inReported.has(f.id)) return
    const seen = new Map()
    const path = []
    let cur = f.id
    while (cur != null && flowEdges.has(cur) && !seen.has(cur)) {
      seen.set(cur, path.length)
      path.push(cur)
      cur = flowEdges.get(cur)
    }
    if (cur != null && seen.has(cur)) {
      const cycle = path.slice(seen.get(cur))
      if (!cycle.some(id => inReported.has(id))) warnings.push({ kind: "flow_cycle", flowIds: cycle })
    }
    path.forEach(id => inReported.add(id))
  })

  return warnings
}
