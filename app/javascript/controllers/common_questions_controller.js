import { Controller } from "@hotwired/stimulus"

// Per-question Common Questions picker in the create wizard. Each set is a
// <details> group; this keeps the set's "select all" box in sync with the
// individual question boxes and updates the "selected/total" count shown in
// the summary, so a collapsed set still tells you how much you've picked.
export default class extends Controller {
  // "Select all" toggled — match every question box in this set.
  toggleSet(e) {
    const set = e.target.closest(".cq-set")
    set.querySelectorAll("input[name='common_question_ids[]']").forEach(cb => { cb.checked = e.target.checked })
    this._refresh(set)
  }

  // A single question toggled — reconcile the set's "select all" + count.
  update(e) {
    this._refresh(e.target.closest(".cq-set"))
  }

  connect() {
    this.element.querySelectorAll(".cq-set").forEach(set => this._refresh(set))
  }

  _refresh(set) {
    if (!set) return
    const boxes = [...set.querySelectorAll("input[name='common_question_ids[]']")]
    const checked = boxes.filter(b => b.checked).length

    const all = set.querySelector("[data-cq-all]")
    if (all) {
      all.checked = boxes.length > 0 && checked === boxes.length
      all.indeterminate = checked > 0 && checked < boxes.length
    }
    const count = set.querySelector("[data-cq-count]")
    if (count) count.textContent = `${checked}/${boxes.length}`
  }
}
