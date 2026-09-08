// Renders every board in index.html to shots/*.png, plus the share image at
// 1:1 as JPEG (quality 82) so the committed sample doubles as a check on the
// ≤ 300 KB budget WhatsApp's large preview needs.
//
//   node shoot.mjs            # from this directory
//   CHROMIUM=/path/to/chrome node shoot.mjs
//
// Playwright is imported from the global install (this repo has no
// package.json — it is importmap-based); Chromium is the pre-installed one
// the verify skill uses (.claude/skills/verify/SKILL.md).
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"
import path from "node:path"
import fs from "node:fs"

const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_DIR || "/opt/node22/lib/node_modules/playwright")

const here  = path.dirname(fileURLToPath(import.meta.url))
const url   = "file://" + path.join(here, "index.html")
const shots = path.join(here, "shots")
fs.mkdirSync(shots, { recursive: true })

const BOARDS = [
  ["intro",    "00-worked-example"],
  ["board-a1", "01-mobile-end-screen"],
  ["board-a2", "02-mobile-share-sheet"],
  ["board-a3", "03-mobile-native-sheet"],
  ["board-b1", "04-desktop-end-screen"],
  ["board-b2", "05-desktop-share-modal"],
  ["board-c",  "06-unfurls"],
  ["board-d1", "07-share-image"],
  ["board-d2", "08-share-image-crops"],
  ["board-e",  "09-editor-share-block"],
  ["board-f",  "10-dashboard-tile"],
  ["spec",     "11-spec"],
]

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" })

const ready = async (page) => {
  await page.goto(url)
  await page.evaluate(() => document.fonts.ready)
  await page.waitForTimeout(150)
}

// Boards at 2× for review.
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2 })
await ready(page)
for (const [id, name] of BOARDS) {
  await page.locator("#" + id).screenshot({ path: path.join(shots, name + ".png") })
  console.log("shot", name)
}

// The share image itself at 1:1 — exactly what /play/:token/share.jpg would serve.
const one = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 })
await ready(one)
const og = one.locator("#og-full")
await og.screenshot({ path: path.join(shots, "07-share-image-1200x630.png") })
await og.screenshot({ path: path.join(shots, "07-share-image-1200x630.jpg"), type: "jpeg", quality: 82 })
const bytes = fs.statSync(path.join(shots, "07-share-image-1200x630.jpg")).size
console.log(`share image jpeg: ${bytes} bytes (${bytes <= 300 * 1024 ? "within" : "OVER"} the 300 KB WhatsApp budget)`)

await browser.close()
