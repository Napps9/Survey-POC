// Renders every board in index.html to shots/*.png.
//
//   node shoot.mjs            # from this directory
//   CHROMIUM=/path/to/chrome node shoot.mjs
//
// Playwright is imported from the global install (this repo has no
// package.json — it is importmap-based); Chromium is the pre-installed one the
// verify skill uses (.claude/skills/verify/SKILL.md). Same shape as
// ../responder-share/shoot.mjs; adding a board means adding one row to BOARDS.
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
  ["board-a1", "01-end-screen-mobile"],
  ["board-a2", "02-join-block-states"],
  ["board-a3", "03-end-screen-desktop"],
  ["board-b",  "04-sign-in-email"],
  ["board-c1", "05-you-mobile"],
  ["board-c2", "06-you-desktop"],
  ["board-d",  "07-one-verto"],
  ["board-e",  "08-wallet"],
  ["board-f",  "09-impact"],
  ["board-g",  "10-follow-ups"],
  ["board-h",  "11-next-one-out-email"],
  ["board-i",  "12-editor-join-block"],
  ["board-j",  "13-editor-impact-block"],
  ["board-k",  "14-dashboard-tile"],
  ["spec",     "15-spec"],
]

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" })
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2 })
await page.goto(url)
await page.evaluate(() => document.fonts.ready)
await page.waitForTimeout(150)

let missing = 0
for (const [id, name] of BOARDS) {
  const el = page.locator("#" + id)
  if (await el.count() === 0) { console.log("MISSING #" + id); missing++; continue }
  await el.screenshot({ path: path.join(shots, name + ".png") })
  console.log("shot", name)
}
await browser.close()
if (missing) { console.error(`${missing} board(s) missing`); process.exit(1) }
