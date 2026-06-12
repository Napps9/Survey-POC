import { Controller } from "@hotwired/stimulus"

// The ⓘ on each question type opens a modal explaining what that type is and
// when to use it. Text is carried on the button's data attributes (sourced
// from config/card_types.yml), so this stays a tiny, self-contained
// controller separate from the heavy type-panel one.
export default class extends Controller {
  static targets = ["modal", "icon", "name", "body"]

  open(e) {
    e.stopPropagation() // don't also select/apply the type underneath
    const d = e.currentTarget.dataset
    this.iconTarget.textContent = d.typeIcon || "ⓘ"
    this.nameTarget.textContent = d.typeName || ""
    this.bodyTarget.textContent = d.typeExplainer || ""
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.style.overflow = ""
  }

  backdrop(e) {
    if (e.target === e.currentTarget) this.close()
  }

  closeOnEsc() {
    if (!this.modalTarget.classList.contains("hidden")) this.close()
  }
}
