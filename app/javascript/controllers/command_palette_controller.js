import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["backdrop", "input", "item", "empty", "userPopover", "workspacePopover"]

  connect() {
    this.boundKeydown = this.handleGlobalKeydown.bind(this)
    this.boundDocClick = this.handleDocClick.bind(this)
    document.addEventListener("keydown", this.boundKeydown)
    document.addEventListener("click", this.boundDocClick)
    this.activeIndex = -1
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeydown)
    document.removeEventListener("click", this.boundDocClick)
  }

  handleGlobalKeydown(event) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault()
      this.isOpen() ? this.close() : this.open()
      return
    }
    if (!this.isOpen()) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    } else if (event.key === "ArrowDown") {
      event.preventDefault()
      this.move(1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.move(-1)
    } else if (event.key === "Enter") {
      const items = this.visibleItems()
      if (this.activeIndex >= 0 && items[this.activeIndex]) {
        event.preventDefault()
        items[this.activeIndex].click()
      }
    }
  }

  // Both chrome popovers (user, workspaces) close on an outside click. Kept as
  // a list rather than one hardcoded pair so adding a third doesn't reintroduce
  // a popover that only closes by navigating away.
  get _popovers() {
    return [
      [this.hasUserPopoverTarget && this.userPopoverTarget, "toggleUser"],
      [this.hasWorkspacePopoverTarget && this.workspacePopoverTarget, "toggleWorkspace"]
    ].filter(([el]) => el)
  }

  handleDocClick(event) {
    this._popovers.forEach(([popover, action]) => {
      if (popover.hidden) return
      if (popover.contains(event.target)) return
      if (event.target.closest(`[data-action*='command-palette#${action}']`)) return
      popover.hidden = true
    })
  }

  isOpen() {
    return this.hasBackdropTarget && !this.backdropTarget.hidden
  }

  open(event) {
    if (event) event.preventDefault()
    if (!this.hasBackdropTarget) return
    this.backdropTarget.hidden = false
    requestAnimationFrame(() => {
      this.inputTarget.focus()
      this.inputTarget.select()
    })
    this.activeIndex = -1
    this.updateActive()
  }

  close(event) {
    if (event) event.preventDefault()
    if (!this.hasBackdropTarget) return
    this.backdropTarget.hidden = true
    this.inputTarget.value = ""
    this.filter()
  }

  closeOnBackdrop(event) {
    if (event.target === this.backdropTarget) {
      this.close()
    }
  }

  filter() {
    const q = this.inputTarget.value.trim().toLowerCase()
    let anyVisible = false
    this.itemTargets.forEach(item => {
      const text = (item.dataset.searchText || item.textContent).toLowerCase()
      const match = !q || text.includes(q)
      item.style.display = match ? "" : "none"
      if (match) anyVisible = true
    })
    this.element.querySelectorAll("[data-section]").forEach(section => {
      const items = section.querySelectorAll("[data-command-palette-target='item']")
      const anyMatch = Array.from(items).some(i => i.style.display !== "none")
      section.style.display = anyMatch ? "" : "none"
    })
    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = anyVisible
    }
    this.activeIndex = -1
    this.updateActive()
  }

  visibleItems() {
    return this.itemTargets.filter(i => i.style.display !== "none")
  }

  move(delta) {
    const items = this.visibleItems()
    if (items.length === 0) return
    this.activeIndex = (this.activeIndex + delta + items.length) % items.length
    this.updateActive()
  }

  updateActive() {
    const items = this.visibleItems()
    this.itemTargets.forEach(i => { i.dataset.active = "false" })
    if (this.activeIndex >= 0 && items[this.activeIndex]) {
      items[this.activeIndex].dataset.active = "true"
      items[this.activeIndex].scrollIntoView({ block: "nearest" })
    }
  }

  // Opening one popover closes the other: on a 56px bar two open at once overlap.
  toggleUser(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.hasWorkspacePopoverTarget) this.workspacePopoverTarget.hidden = true
    if (!this.hasUserPopoverTarget) return
    this.userPopoverTarget.hidden = !this.userPopoverTarget.hidden
  }

  toggleWorkspace(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.hasUserPopoverTarget) this.userPopoverTarget.hidden = true
    if (!this.hasWorkspacePopoverTarget) return
    this.workspacePopoverTarget.hidden = !this.workspacePopoverTarget.hidden
  }
}
