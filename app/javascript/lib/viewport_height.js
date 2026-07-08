// Mobile browsers — including several in-app browsers such as Slack's — can
// be inconsistent about the CSS `dvh` unit, sometimes locking a fixed-height
// overlay to the wrong toolbar state on first paint. That leaves elements
// pinned to the bottom of the box (like the player's footer/Next button)
// below the actually-visible viewport, with no scroll to reach them. Track
// the real measured height instead so CSS can fall back to it.
const setAppViewportHeight = () => {
  const h = window.visualViewport ? window.visualViewport.height : window.innerHeight
  document.documentElement.style.setProperty("--app-100vh", `${h}px`)
}

setAppViewportHeight()
window.addEventListener("resize", setAppViewportHeight)
window.addEventListener("orientationchange", setAppViewportHeight)
if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", setAppViewportHeight)
}
