import { Controller } from "@hotwired/stimulus"

// Selects the element's text (e.g. a readonly link input) when clicked.
// CSP-friendly replacement for inline onclick="this.select()".
export default class extends Controller {
  select() {
    if (this.element.select) this.element.select()
  }
}
