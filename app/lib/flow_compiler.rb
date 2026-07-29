# Compiles first-class flows down to the runtime primitives LogicGraph already
# resolves. A flow (see Survey.sanitize_flows) is authoring metadata — a named,
# coloured group of cards whose membership rides on each card as `flow_id`.
# Compilation writes the plumbing the player actually follows:
#
#   * every member gets an explicit `next` pointer to the following member
#     (flow order IS deck order), and
#   * the last member gets the flow's `exit` ({ "card" => cid } to converge,
#     { "end" => id } to finish on a branch end screen), or its `next` cleared
#     when no exit is set (creator's choice: fall through linearly).
#
# Pure and idempotent; cards outside any flow are never touched, so legacy
# hand-wired decks round-trip byte-identical. Compilation is authoritative for
# members — a stale manual `next` on a member is overwritten by design, which
# is what keeps a reordered flow internally consistent. Answer routes on a
# member still outrank its compiled `next` at runtime (LogicGraph.next_index
# precedence), so a routing question inside a flow can branch out of it.
#
# Mirrored client-side by survey_editor_controller.js#_compileFlows so the
# flow map and autosave payloads agree mid-edit — this module is the server
# backstop run on every save (SurveysController#update) and the test oracle.
# Keep the two in sync.
module FlowCompiler
  module_function

  # The cards belonging to a flow, in deck order.
  def members(cards, flow_id)
    return [] if flow_id.to_s.empty?
    Array(cards).select { |c| c.is_a?(Hash) && c["flow_id"] == flow_id }
  end

  # Normalise a flow's exit into a single-key routing target, or nil when it
  # isn't usable. An "end" wins over a "card" if a malformed hash carries both,
  # matching LogicGraph.next_index's resolution order.
  def valid_exit(target)
    return nil unless target.is_a?(Hash)
    return { "end" => target["end"].to_s } if target["end"].to_s != ""
    return { "card" => target["card"].to_s } if target["card"].to_s != ""
    nil
  end

  # Mutates and returns `cards`, rewriting each flow's member chain + exit.
  def compile!(cards, flows)
    Array(flows).each do |flow|
      next unless flow.is_a?(Hash)
      chain = members(cards, flow["id"])
      next if chain.empty?
      chain.each_cons(2) { |a, b| a["next"] = { "card" => b["cid"].to_s } }
      exit_target = valid_exit(flow["exit"])
      exit_target ? chain.last["next"] = exit_target : chain.last.delete("next")
    end
    cards
  end
end
