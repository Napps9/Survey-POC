import { Controller } from "@hotwired/stimulus"

// Submits the controller's <form> when a field dispatches its action — a
// CSP-friendly replacement for inline onchange="this.form.requestSubmit()".
//
//   <form data-controller="autosubmit">
//     <input type="checkbox" data-action="change->autosubmit#submit">
//   </form>
export default class extends Controller {
  submit() {
    if (this.element.requestSubmit) this.element.requestSubmit()
    else this.element.submit()
  }
}
