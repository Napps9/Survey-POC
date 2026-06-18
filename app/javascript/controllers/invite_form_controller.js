import { Controller } from "@hotwired/stimulus"

// Toggles between the "create account" and "sign in" panels on the invite page
// and focuses the first field. CSP-friendly replacement for the inline onclick
// toggles.
//
//   <div data-controller="invite-form">
//     <div data-invite-form-target="signup">…</div>
//     <div data-invite-form-target="signin" hidden>…</div>
//     <button data-action="invite-form#showSignin">Sign in instead</button>
//   </div>
export default class extends Controller {
  static targets = ["signup", "signin"]

  showSignin() { this.reveal(this.signinTarget, this.signupTarget) }
  showSignup() { this.reveal(this.signupTarget, this.signinTarget) }

  reveal(show, hide) {
    if (hide) hide.hidden = true
    if (!show) return
    show.hidden = false
    const field = show.querySelector("input")
    if (field) field.focus()
  }
}
