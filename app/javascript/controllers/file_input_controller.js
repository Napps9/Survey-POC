import { Controller } from "@hotwired/stimulus"

// Shows the chosen filename next to a hidden file input. CSP-friendly
// replacement for the inline onchange that wrote the file name into a span.
//
//   <label data-controller="file-input" data-file-input-empty-value="No file chosen">
//     <span data-file-input-target="name">No file chosen</span>
//     <input type="file" data-action="change->file-input#show">
//   </label>
export default class extends Controller {
  static targets = ["name"]
  static values = { empty: String }

  show(event) {
    const files = event.target.files
    this.nameTarget.textContent = files && files[0] ? files[0].name : this.emptyValue
  }
}
