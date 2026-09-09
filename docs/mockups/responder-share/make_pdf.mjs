// Renders index.html to a single shareable PDF — one board per page, each page
// sized to its own board.
//
//   node make_pdf.mjs            # -> responder-share-mockups.pdf
//
// Chromium print-to-PDF rather than stitching the PNGs in shots/: the page is
// HTML, CSS and inline SVG throughout, so every label, note and spec line stays
// real vector text — sharp at any zoom, selectable and searchable — where an
// image-per-page PDF would bake it all into pixels.
//
// Why a page per board instead of one uniform page size: the boards run from
// 448px (the dashboard tile) to 2025px (the seven unfurls). One page height tall
// enough for the tallest leaves most pages two-thirds empty; one short enough to
// suit the typical board orphans two notes of board C onto a blank page. Sizing
// each page to its own board costs nothing and keeps every artboard whole.
//
// Emits per-section PDFs into a temp dir; merge_pdf.py stitches and numbers them.
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"
import path from "node:path"
import fs from "node:fs"

const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_DIR || "/opt/node22/lib/node_modules/playwright")

const here = path.dirname(fileURLToPath(import.meta.url))
const tmp  = process.env.PDF_PARTS_DIR || path.join(here, ".pdf-parts")
fs.rmSync(tmp, { recursive: true, force: true })
fs.mkdirSync(tmp, { recursive: true })

const WIDTH = 1500
const PAD   = 26   // breathing room under the last line of a board

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" })
const page = await browser.newPage({ viewport: { width: WIDTH, height: 1200 } })
await page.goto("file://" + path.join(here, "index.html"))
await page.evaluate(() => document.fonts.ready)
await page.emulateMedia({ media: "print" })
await page.waitForTimeout(250)

// Page 1 is the cover (masthead, contents, worked example); then one per board.
const sections = await page.evaluate(() =>
  ["__cover__", ...[...document.querySelectorAll("section.board, section.spec")].map(el => el.id)]
)

// Isolating a section means hiding its siblings, and dropping the forced page
// break that would otherwise open the file on a blank sheet.
await page.addStyleTag({ content: `
  body.pdf-isolate header.hero, body.pdf-isolate nav.toc,
  body.pdf-isolate main.wrap > *:not(.pdf-show) { display: none !important; }
  body.pdf-isolate .pdf-show { break-before: auto !important; }
  body.pdf-cover main.wrap > *:not(section.intro) { display: none !important; }
  body.pdf-cover section.intro { break-after: auto !important; }
` })

const parts = []
for (const [i, id] of sections.entries()) {
  const height = await page.evaluate((sid) => {
    document.body.classList.remove("pdf-isolate", "pdf-cover")
    document.querySelectorAll(".pdf-show").forEach(el => el.classList.remove("pdf-show"))
    if (sid === "__cover__") {
      document.body.classList.add("pdf-cover")
      return ["header.hero", "nav.toc", "section.intro"]
        .reduce((sum, s) => sum + (document.querySelector(s)?.getBoundingClientRect().height || 0), 0)
    }
    document.body.classList.add("pdf-isolate")
    const el = document.getElementById(sid)
    el.classList.add("pdf-show")
    return el.getBoundingClientRect().height
  }, id)

  const file = path.join(tmp, `${String(i).padStart(2, "0")}-${id.replace(/\W+/g, "-")}.pdf`)
  await page.pdf({
    path: file,
    width: `${WIDTH}px`,
    height: `${Math.ceil(height) + PAD}px`,
    printBackground: true,
    margin: { top: "0px", bottom: "0px", left: "0px", right: "0px" },
  })
  parts.push(file)
  console.log(`  ${id} — ${Math.ceil(height)}px`)
}

await browser.close()
console.log(`${parts.length} parts in ${path.relative(here, tmp)}/`)
