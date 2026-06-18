import { Controller } from "@hotwired/stimulus"

// Applies a set of inline style properties on hover (or focus) and restores
// them on leave (or blur). A CSP-friendly, data-driven replacement for the
// inline onmouseover/onmouseout/onfocus/onblur="this.style.* = ..." handlers.
//
//   data-controller="hover"
//   data-hover-over-value='{"background":"#00C4AB"}'
//   data-hover-out-value='{"background":"#01EACB"}'
//   data-hover-on-value="focus"   (optional; default "hover")
//
// Style keys are JS camelCase (background, color, borderColor, boxShadow, …).
export default class extends Controller {
  static values = {
    over: Object,
    out: Object,
    on: { type: String, default: "hover" }
  }

  connect() {
    const focus = this.onValue === "focus"
    this.enterEvent = focus ? "focus" : "mouseenter"
    this.leaveEvent = focus ? "blur" : "mouseleave"
    this.onEnter = () => this.applyStyles(this.overValue)
    this.onLeave = () => this.applyStyles(this.outValue)
    this.element.addEventListener(this.enterEvent, this.onEnter)
    this.element.addEventListener(this.leaveEvent, this.onLeave)
  }

  disconnect() {
    this.element.removeEventListener(this.enterEvent, this.onEnter)
    this.element.removeEventListener(this.leaveEvent, this.onLeave)
  }

  applyStyles(styles) {
    Object.entries(styles || {}).forEach(([k, v]) => { this.element.style[k] = v })
  }
}
