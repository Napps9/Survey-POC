import { Controller } from "@hotwired/stimulus"

// Sets the controller's <form> action from a selected value, substituting it
// into a template. CSP-friendly replacement for the inline onchange that built
// the alliance URL from the picker value.
//
//   <form data-controller="form-action-select"
//         data-form-action-select-template-value="/alliances/:id/alliance_vertos">
//     <select data-action="change->form-action-select#update">…</select>
//   </form>
export default class extends Controller {
  static values = { template: String }

  update(event) {
    this.element.action = this.templateValue.replace(":id", encodeURIComponent(event.target.value))
  }
}
