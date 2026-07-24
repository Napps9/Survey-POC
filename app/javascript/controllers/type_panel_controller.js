import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// Card types with no answer captured — mirrors CardTypes::NON_QUESTION_TYPES
// (app/lib/card_types.rb) and verto_rules.js's isQuestion.
const NON_QUESTION_TYPES = [ "welcome_card", "token_checkpoint" ]

// Single-pick types whose answers can each route to a different card/end —
// mirrors LogicGraph::ROUTABLE and logic_map_controller's ROUTABLE.
const ROUTABLE_TYPES = [ "multiple_choice", "yes_no", "scenario" ]

// Read the canonical card-type metadata that the editor view emits as a
// JSON blob (sourced from config/card_types.yml). Called from connect()
// so each Turbo navigation re-reads the blob — otherwise the cache from
// the first page visited (e.g. dashboard, which has no blob) sticks.
function loadTypeMeta() {
  let raw = {}
  try {
    raw = JSON.parse(document.getElementById("card-types")?.textContent || "{}")
  } catch (_) {
    raw = {}
  }
  return Object.fromEntries(
    Object.entries(raw).map(([key, t]) => [key, {
      badge:   t.badge,
      css:     t.badge_css,
      label:   t.panel_label,
      eyebrow: t.eyebrow,
    }])
  )
}

// Per-locale "how to answer" captions — see application_helper.rb
// #card_eyebrows_i18n. Only used to caption a card just switched to a new
// type (_applyToCard); translation tabs lock the type picker (CSS
// .editing-translation .type-list), so this only ever needs the primary
// locale's caption, not whichever tab happens to be active.
function loadEyebrows() {
  try {
    return JSON.parse(document.getElementById("card-eyebrows-i18n")?.textContent || "{}")
  } catch (_) {
    return {}
  }
}

// Read the Awareness/Intention/Agency + enabling-condition metadata the editor
// view emits as a JSON blob (sourced from config/competencies.yml via
// Framework.to_json). Used to label the "Why" tab badges. Same re-read-on-
// connect rationale as loadTypeMeta.
function loadFramework() {
  try {
    return JSON.parse(document.getElementById("framework")?.textContent || "{}")
  } catch (_) {
    return {}
  }
}

// Each entry's `note` is shown as the natural-language reason this type
// works (or doesn't) for the selected card. The `score` only drives the
// fit-tier badge ("Best fit" / "Strong alternative" / etc.).
const COMPATIBILITY = {
  multiple_choice: [
    { type: "select_one_grid",  score: 100, note: "The Playverto default for a single-pick — visual grid feels playful, drives engagement, and lets you anchor each option with imagery or colour." },
    { type: "multiple_choice",  score: 75,  note: "Image list, single pick — small tile left of each option. Fall back to this when labels are long or there are too many options to grid neatly." },
    { type: "select_many_grid", score: 70,  note: "Same visual grid, but lets people pick more than one — switch to this when the answer isn't a single choice." },
    { type: "select_many",      score: 60,  note: "Image list, multi-pick — same tile-left layout, broader answer set; use when the grid can't fit." },
    { type: "yes_no",           score: 55,  note: "Collapses nuance to two answers — only do this if you genuinely want a hard yes/no signal." },
    { type: "range",            score: 40,  note: "Loses the categorical clarity of a list — only swap if the answer is really on a scale." },
  ],
  select_many: [
    { type: "select_many_grid", score: 100, note: "The Playverto default for multi-pick — visual grid with imagery or colour swatches gets richer answers than a flat list." },
    { type: "select_many",      score: 75,  note: "Image list, multi-pick — small tile left of each option. Fall back to this when labels are long or there are too many options to grid neatly." },
    { type: "select_one_grid",  score: 70,  note: "Same visual grid but constrained to a single pick — switch when one decisive answer matters more than breadth." },
    { type: "multiple_choice",  score: 60,  note: "Image list, single pick — same tile-left layout, sharpest read but most reductive option here." },
    { type: "prioritise",       score: 65,  note: "Same options, but respondents drag them into an order of priority — richer data (the ORDER of preference), not just which they picked." },
  ],
  prioritise: [
    { type: "prioritise",       score: 100, note: "Drag-to-rank list — respondents order the options highest to lowest, so you learn the order of preference. Best with about five options." },
    { type: "select_many",      score: 65,  note: "Same list without the ordering — switch if you only need which options they'd pick, not the order." },
    { type: "select_one_grid",  score: 45,  note: "Collapses the ranking to a single visual pick — only if one decisive answer matters more than the order." },
  ],
  select_one_grid: [
    { type: "select_one_grid",  score: 100, note: "Visual single-pick — best when imagery or colour does the talking and you want a fast, gut response." },
    { type: "select_many_grid", score: 80,  note: "Same imagery, multi-pick — better when more than one option might resonate." },
    { type: "multiple_choice",  score: 55,  note: "Image list, single pick — small tile left of each option. Switch when options are long or there are too many to fit a grid." },
    { type: "select_many",      score: 40,  note: "Image list, multi-pick — same tile-left layout, loses the single-pick clarity." },
  ],
  select_many_grid: [
    { type: "select_many_grid", score: 100, note: "Visual multi-pick — best when respondents may identify with several image-led options at once." },
    { type: "select_one_grid",  score: 80,  note: "Same visual feel but constrained to one — pick this if you need a single decisive choice." },
    { type: "select_many",      score: 55,  note: "Image list, multi-pick — small tile left of each option. Fall back when labels are long or there are too many to grid." },
    { type: "multiple_choice",  score: 40,  note: "Image list, single pick — same tile-left layout, sharpest read but most reductive option here." },
  ],
  tap_card: [
    { type: "tap_card",         score: 100, note: "Quick, gamified gut reactions — perfect for testing several short statements without survey fatigue." },
    { type: "range",            score: 60,  note: "Replaces speed with nuance — use if you'd rather see how strongly people agree than how fast." },
    { type: "rating",           score: 55,  note: "Stars give a familiar scale, but you lose the rapid-fire feel of swipe." },
    { type: "select_one_grid",  score: 40,  note: "Removes the playful swipe mechanic — only swap if the question really is a single static choice." },
  ],
  scenario: [
    { type: "scenario",         score: 100, note: "A short story respondents turn through page by page, then a 2–3 option choice on the last page — best for longer, situational prompts that would overwhelm a single card." },
    { type: "multiple_choice",  score: 45,  note: "Drops the narrative build-up for a plain single-pick list — switch if the story context isn't adding anything." },
    { type: "yes_no",           score: 35,  note: "Strips it to a bare binary — only if the story genuinely reduces to a yes/no." },
  ],
  range: [
    { type: "range",            score: 100, note: "Best at capturing strength of feeling, and the reactive animated character makes answering feel rewarding — a clean distribution plus an engaging visual." },
    { type: "nps",              score: 90,  note: "Classic 0–10 scale on a compact vertical slider — switch for a quieter, traditional feel without the animation." },
    { type: "rating",           score: 85,  note: "Similar shape, but stars are more familiar and a touch less expressive." },
    { type: "tap_card",         score: 50,  note: "Trades the scale for a yes/no per statement — more engaging, less granular." },
    { type: "yes_no",           score: 30,  note: "Strips the scale to two answers — most data goes with it. Only use if the binary is the insight." },
  ],
  rating: [
    { type: "rating",           score: 100, note: "Star scale is instantly understood and gives a comparable score across questions." },
    { type: "nps",              score: 80,  note: "Classic 0–10 feel on a compact vertical slider — picks up where stars feel generic." },
    { type: "range",            score: 88,  note: "More expressive scale with custom endpoints and a reactive animated character — better when the spectrum isn't generic 'good/bad'." },
    { type: "tap_card",         score: 50,  note: "Loses the scale, but more engaging if you want a quick gut take across several items." },
    { type: "select_one_grid",  score: 35,  note: "Flattens the scale into discrete labelled tiles — loses the smoothness people respond to in stars." },
  ],
  nps: [
    { type: "nps",              score: 100, note: "Compact 0–10 vertical scale — clean and familiar for opinion / satisfaction questions." },
    { type: "range",            score: 88,  note: "Same 5-point opinion scale with a reactive animated character — switch when an engaging visual lifts response quality." },
    { type: "rating",           score: 80,  note: "Star scale is the familiar baseline — switch if a horizontal star rating fits the audience better." },
    { type: "tap_card",         score: 45,  note: "Replace the scale with a quick gut yes/no across several statements — only if you have multiple to test." },
    { type: "yes_no",           score: 30,  note: "Collapses the scale to two answers — most signal goes with it. Only use if the binary is the insight." },
  ],
  yes_no: [
    { type: "yes_no",           score: 100, note: "Crisp signal when you genuinely need a binary — easy to read and easy to answer." },
    { type: "select_one_grid",  score: 75,  note: "Adds nuance with a few defined visual options — better when 'yes/no' is hiding the real answer." },
    { type: "range",            score: 55,  note: "Adds a 5-point scale with a reactive animated character — better when degree matters and you want an engaging visual." },
    { type: "nps",              score: 45,  note: "Adds a compact 0–10 vertical scale — better when degree matters more than the binary." },
    { type: "tap_card",         score: 35,  note: "Run a quick yes/no across several statements at once — only swap if you have multiple to test." },
  ],
  open_ended: [
    { type: "open_ended",       score: 100, note: "Lets people answer in their own words — richest qualitative signal, but harder to aggregate." },
    { type: "select_one_grid",  score: 45,  note: "Trades raw quotes for fast, comparable visual categories — pick this if you already know the likely answers." },
    { type: "range",            score: 30,  note: "Only works if the answer collapses to a single scale — usually loses the point of going open-ended." },
  ],
  welcome_card: [
    { type: "welcome_card",     score: 100, note: "Sets the tone before any questions — ideal first card for cold audiences who need context." },
  ],
}

const DEFAULT_OPTIONS = {
  range:            ["Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree"],
  nps:              ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"],
  rating:           ["Poor", "Fair", "Good", "Great", "Excellent"],
  multiple_choice:  ["Option A", "Option B", "Option C"],
  select_many:      ["Option A", "Option B", "Option C", "Option D", "Option E"],
  prioritise:       ["Option A", "Option B", "Option C", "Option D"],
  yes_no:           ["Yes", "No"],
  select_one_grid:  ["A", "B", "C", "D"],
  select_many_grid: ["A", "B", "C", "D"],
  tap_card:         ["Statement 1", "Statement 2", "Statement 3", "Statement 4", "Statement 5"],
  scenario:         ["Option A", "Option B"],
  open_ended:       [],
  welcome_card:     [],
}

// Default narrative pages for a card freshly switched to Scenario — one
// blank page (the .book-page-text placeholder invites the creator to write).
const DEFAULT_PAGES = {
  scenario: [ { id: "", text: "" } ],
}

// Default NPS label count (0–10). Server-side too (NpsHelper::NPS_STEPS).
// The actual step count follows the label count, so a 4/5-point or agree
// scale works too. Keep in sync.
const NPS_STEPS = 11

const SWIPE_FILLS = [
  ["#d4edda","#a8d5b5"], ["#d1ecf1","#9fd5df"], ["#fff3cd","#ffd88a"],
  ["#f8d7da","#f5a8b0"], ["#e2d9f3","#c3aee8"]
]

function esc(s) {
  return String(s ?? "").replace(/&/g,"&amp;").replace(/</g,"&lt;")
                       .replace(/>/g,"&gt;").replace(/"/g,"&quot;")
}

// Bucket a 0–100 compatibility score into a short, plain-English fit tier.
function fitTier(score) {
  if (score >= 100) return t("editor.fit_best")
  if (score >= 80)  return t("editor.fit_strong")
  if (score >= 60)  return t("editor.fit_solid")
  if (score >= 40)  return t("editor.fit_workable")
  return t("editor.fit_sparingly")
}

// HTML builders for the right-side interactive component on each card
const COMPONENTS = {
  multiple_choice: (opts) => choiceListHtml(opts, "single"),
  select_many:     (opts) => choiceListHtml(opts, "multi"),
  prioritise:      (opts) => prioritiseHtml(opts),

  yes_no: () => `
    <ul class="choice-list choice-list--yesno" data-controller="picker" data-picker-mode-value="single">
      ${[["Yes", 1], ["No", 4]].map(([label, bg]) => `
        <li class="choice-list-item pick-item" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false">
          <div class="choice-list-tile choice-bg-${bg}"></div>
          <span class="pick-text choice-list-label" contenteditable="true">${label}</span>
          <span class="choice-list-tick pick-dot">✓</span>
        </li>`).join("")}
    </ul>`,

  select_one_grid:  (opts) => gridHtml(opts, "single"),
  select_many_grid: (opts) => gridHtml(opts, "multi"),

  tap_card: (opts) => `
    <div class="rotate-wrap" data-controller="tap-stack card-editor">
      <div class="rotate-card-stack">
        ${opts.map((o,i) => {
          const [a,b] = SWIPE_FILLS[i % SWIPE_FILLS.length]
          return `<div class="rotate-card" data-tap-stack-target="card"
                       style="background:linear-gradient(135deg,${a},${b});">
                    <span contenteditable="true" style="font-family:'ABeeZee',sans-serif;font-size:14px;color:#111;text-align:center;">${esc(o)}</span>
                    <button type="button" class="tap-card-image-btn" data-action="click->media-picker#openTapOption" data-media-picker-option-index="${i}" title="Change this statement's image">
                      <span aria-hidden="true"><svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><path d="M21 15l-5-5L5 21"></path></svg></span>
                    </button>
                    <button type="button" class="tap-card-delete" data-action="click->card-editor#deleteOption">×</button>
                  </div>`
        }).join("")}
      </div>
      <div class="swipe-indicator">
        <span style="color:#D80027;font-weight:700">← No</span>
        <span class="mx-3">drag card to answer</span>
        <span style="color:#01EACB;font-weight:700">Yes →</span>
      </div>
      <div class="rotate-actions">
        <button type="button" class="rotate-action-btn rotate-action-no"
                data-action="click->tap-stack#pick" data-tap-stack-direction="left">✕</button>
        <button type="button" class="rotate-action-btn rotate-action-yes"
                data-action="click->tap-stack#pick" data-tap-stack-direction="right">✓</button>
      </div>
      <button type="button" class="tap-add-btn" data-action="click->card-editor#addTapOption">＋ Add statement</button>
    </div>`,

  // Mirrors the "when scenario" branch in _card_component.html.erb — a book
  // stack of narrative pages (ctx.pages) plus the reused single-select
  // .choice-list as the final page. Always built editable (client-side type
  // switching only happens in the editor); scenario_controller.js drives the
  // page-turn nav once this HTML lands in the DOM.
  scenario: (opts, ctx = {}) => {
    const pages = (ctx.pages && ctx.pages.length) ? ctx.pages : [ { id: "", text: "" } ]
    const pagesHtml = pages.map((p, i) => `
      <div class="book-page" data-scenario-target="page" data-page-id="${esc(p.id || "")}">
        <div class="book-page-scroll">
          <div class="book-page-kicker" data-scenario-target="kicker">Page ${i + 1} of ${pages.length}</div>
          <div class="book-page-text" contenteditable="true" data-scenario-target="pageText"
               data-placeholder="Write this page…">${esc(p.text || "")}</div>
        </div>
        <div class="book-page-corner">${i + 1}</div>
        <div class="book-page-fade"></div>
      </div>`).join("")
    const answerHtml = `
      <div class="book-page is-answer" data-scenario-target="page">
        <div class="book-page-scroll">
          <div class="book-page-kicker">Answer options</div>
          <ul class="choice-list choice-list--single" data-controller="picker card-editor" data-picker-mode-value="single">
            ${opts.map((o, i) => `
              <li class="choice-list-item pick-item" data-picker-target="item"
                  data-action="click->picker#pick" data-selected="false">
                <div class="choice-list-tile choice-bg-${(i % 6) + 1}"></div>
                <span class="pick-text choice-list-label" contenteditable="true">${esc(o)}</span>
                <span class="choice-list-tick pick-dot">✓</span>
                <button type="button" class="pick-item-delete" data-action="click->card-editor#deleteOption">×</button>
              </li>`).join("")}
            <li class="pick-add-btn" data-action="click->card-editor#addPickOption" data-card-editor-add>
              <span>＋</span> Add option
            </li>
          </ul>
        </div>
        <div class="book-page-fade"></div>
      </div>`
    return `
      <div class="book-wrap" data-controller="scenario card-editor" data-scenario-editable-value="true">
        <div class="book-stack" data-scenario-target="stack">${pagesHtml}${answerHtml}</div>
        <div class="book-edit-tools" data-scenario-target="editTools">
          <button type="button" class="book-tool-btn danger" data-scenario-target="delPageBtn" data-action="click->scenario#deletePage">✕ Delete this page</button>
          <button type="button" class="book-tool-btn" data-scenario-target="addPageBtn" data-action="click->scenario#addPage">＋ Add page</button>
        </div>
        <div class="book-dots" data-scenario-target="dots"></div>
        <div class="book-nav-row">
          <button type="button" class="book-chevron" data-scenario-target="prevBtn" data-action="click->scenario#back" aria-label="Previous page">‹</button>
          <button type="button" class="next-btn" data-scenario-target="nextBtn" data-action="click->scenario#next">Next page ›</button>
        </div>
        <div class="book-live" data-scenario-target="live" aria-live="polite"></div>
      </div>`
  },

  range: (opts, ctx = {}) => sliderHtml(opts, ctx),

  nps: (opts, ctx = {}) => npsHtml(opts, ctx.npsShape),

  rating: (opts, ctx = {}) => {
    const icon = ctx.ratingIcon || { on: "★", off: "☆", kind: "star" }
    const labels = opts.length >= 2 ? opts : ["Poor", "Fair", "Good", "Great", "Excellent"]
    const first  = labels[0] || "Poor"
    const last   = labels[labels.length - 1] || "Excellent"
    return `
      <div class="rating-wrap rating-kind-${icon.kind}" data-controller="rating">
        <div class="rating-stars">
          ${[0,1,2,3,4].map(i => `
            <span class="rating-star"
                  data-rating-target="star"
                  data-rating-index="${i}"
                  data-rating-on="${icon.on}"
                  data-rating-off="${icon.off}"
                  data-action="click->rating#pick mouseover->rating#hover mouseout->rating#unhover">${icon.off}</span>
          `).join("")}
        </div>
        <div class="rating-labels">
          <span class="rating-label" contenteditable="true">${esc(first)}</span>
          <span class="rating-label" contenteditable="true">${esc(last)}</span>
        </div>
      </div>`
  },

  open_ended: () => `
    <div class="freeform-wrap" data-controller="freeform" data-freeform-max-value="200">
      <textarea class="freeform-textarea" placeholder="Type answer…"
                data-freeform-target="input"
                data-action="input->freeform#update"></textarea>
      <div class="freeform-counter" data-freeform-target="counter">0/200 Characters</div>
    </div>`,

  welcome_card: () => "",
}

function prioritiseHtml(opts) {
  return `
    <ul class="choice-list prioritise-list" data-controller="prioritise card-editor">
      ${opts.map((o, i) => `
        <li class="choice-list-item pick-item prioritise-item" data-prioritise-target="item"
            data-action="pointerdown->prioritise#start">
          <span class="prioritise-rank" data-prioritise-target="rank">${i + 1}</span>
          <div class="choice-list-tile choice-bg-${(i % 6) + 1}"></div>
          <span class="pick-text choice-list-label" contenteditable="true">${esc(o)}</span>
          <span class="prioritise-grip" aria-hidden="true">⋮⋮</span>
          <button type="button" class="pick-item-delete" data-action="click->card-editor#deleteOption">×</button>
        </li>`).join("")}
      <li class="pick-add-btn" data-action="click->card-editor#addPickOption" data-card-editor-add>
        <span>＋</span> Add option
      </li>
    </ul>`
}

function choiceListHtml(opts, mode) {
  const tick = mode === "multi" ? "pick-square" : "pick-dot"
  return `
    <ul class="choice-list choice-list--${mode}" data-controller="picker card-editor"
        data-picker-mode-value="${mode}">
      ${opts.map((o, i) => `
        <li class="choice-list-item pick-item" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false">
          <div class="choice-list-tile choice-bg-${(i % 6) + 1}"></div>
          <span class="pick-text choice-list-label" contenteditable="true">${esc(o)}</span>
          <span class="choice-list-tick ${tick}">✓</span>
          <button type="button" class="pick-item-delete" data-action="click->card-editor#deleteOption">×</button>
        </li>`).join("")}
      <li class="pick-add-btn" data-action="click->card-editor#addPickOption" data-card-editor-add>
        <span>＋</span> Add option
      </li>
    </ul>`
}

function gridHtml(opts, mode) {
  const cols = opts.length >= 5 ? 3 : 2
  return `
    <ul class="choice-grid choice-grid--${mode} choice-grid-${cols}" data-controller="picker"
        data-picker-mode-value="${mode}">
      ${opts.map((o,i) => `
        <li class="choice-card" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false">
          <div class="choice-card-bg choice-bg-${(i % 6) + 1}">
            <div class="choice-overlay"></div>
            <div class="choice-tick">✓</div>
          </div>
          <div class="choice-label" contenteditable="true">${esc(o)}</div>
        </li>`).join("")}
    </ul>`
}

// Mirror of nps_helper.rb's NPS_VESSELS: each themed container is a real
// object silhouette with its own width. [w, cx, hw, kind, path] — see the Ruby
// constant for the field meanings. Keep the two in sync.
const NPS_VESSELS = {
  tube:     { w: 68,  cx: 34, hw: 11, kind: null,  path: "M20,16 L20,300 A14,14 0 0 0 48,300 L48,16" },
  pill:     { w: 78,  cx: 39, hw: 13, kind: null,  path: "M24,54 Q24,24 39,24 Q54,24 54,54 L54,286 Q54,316 39,316 Q24,316 24,286 Z" },
  can:      { w: 92,  cx: 46, hw: 26, kind: null,  path: "M16,52 Q16,36 46,36 Q76,36 76,52 L76,288 Q76,304 46,304 Q16,304 16,288 Z" },
  bottle:   { w: 96,  cx: 48, hw: 22, kind: null,  path: "M40,18 L40,74 Q24,94 24,134 L24,296 Q24,306 32,306 L64,306 Q72,306 72,296 L72,134 Q72,94 56,74 L56,18" },
  popsicle: { w: 98,  cx: 49, hw: 26, kind: "pop", path: "M20,54 Q20,26 49,26 Q78,26 78,54 L78,258 Q78,268 68,268 L30,268 Q20,268 20,258 Z" },
  glass:    { w: 106, cx: 53, hw: 28, kind: null,  path: "M18,24 L30,300 Q30,306 36,306 L70,306 Q76,306 76,300 L88,24" },
  beaker:   { w: 116, cx: 58, hw: 38, kind: null,  path: "M18,44 L18,298 Q18,306 26,306 L90,306 Q98,306 98,298 L98,52 L110,40" },
  jar:      { w: 118, cx: 59, hw: 40, kind: "jar", path: "M18,64 L18,298 Q18,306 26,306 L92,306 Q100,306 100,298 L100,64 L94,50 L24,50 Z" },
  flask:    { w: 130, cx: 65, hw: 22, kind: null,  path: "M54,22 L58,34 L58,90 L10,296 Q10,306 20,306 L110,306 Q120,306 120,296 L72,90 L72,34 L76,22" },
  mug:      { w: 132, cx: 54, hw: 34, kind: "mug", path: "M16,52 L16,300 Q16,308 24,308 L84,308 Q92,308 92,300 L92,52" },
}

const NPS_EXTRAS = {
  jar: `<rect x="22" y="22" width="74" height="26" rx="8" fill="#dfe2ee" stroke="#1a1a1a" stroke-width="6"/>`,
  mug: `<path d="M92,116 C130,120 130,244 92,248" fill="none" stroke="#1a1a1a" stroke-width="13" stroke-linecap="round"/>`,
  pop: `<rect x="41" y="260" width="16" height="52" rx="6" fill="#c9a678" stroke="#1a1a1a" stroke-width="4"/>`,
}

function npsBubbles(cx, hw) {
  const rnd = (a, b) => a + Math.random() * (b - a)
  let s = ""
  for (let k = 0; k < 9; k++) {
    const x = rnd(cx - hw * 0.6, cx + hw * 0.6)
    const r = rnd(1.8, 4)
    const start = rnd(150, 235)
    const rise = -(start - rnd(10, 18))
    s += `<circle cx="${x.toFixed(1)}" cy="${start | 0}" r="${r.toFixed(1)}" fill="#ecfffb" class="nps-bub"
      style="--rise:${rise | 0}px;--sway:${rnd(-4, 4).toFixed(1)}px;--dur:${rnd(1.9, 3.4).toFixed(2)}s;--d:${rnd(0, 2.6).toFixed(2)}s"/>`
  }
  return s
}

// The SVG vessel — mirror of nps_helper.rb#nps_vessel_svg.
function npsVesselSvg(shape, v) {
  const wave = y => `M-40,${y} q32.5,-8 65,0 t65,0 t65,0 t65,0 t65,0 L290,430 L-40,430 Z`
  return `
    <svg class="nps-vessel" viewBox="0 0 ${v.w} 340" preserveAspectRatio="xMidYMid meet" aria-hidden="true" focusable="false">
      <defs>
        <linearGradient id="nps-g-${shape}" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" style="stop-color: var(--brand-primary, #16e0c4)"/>
          <stop offset="1" style="stop-color: var(--brand-primary, #01c9ad); stop-opacity: .85"/>
        </linearGradient>
        <clipPath id="nps-c-${shape}"><path d="${v.path} Z"/></clipPath>
      </defs>
      <g clip-path="url(#nps-c-${shape})">
        <rect x="-40" y="0" width="${v.w + 80}" height="340" fill="#eef0f6"/>
        <g class="nps-liquid">
          <g class="nps-surface">
            <path class="nps-wave2" d="${wave(3)}" fill="url(#nps-g-${shape})"/>
            <path class="nps-wave"  d="${wave(0)}" fill="url(#nps-g-${shape})"/>
          </g>
          <rect x="-40" y="4" width="${v.w + 80}" height="440" fill="url(#nps-g-${shape})"/>
          ${npsBubbles(v.cx, v.hw)}
        </g>
      </g>
      <path d="${v.path}" fill="none" stroke="#1a1a1a" stroke-width="6" stroke-linejoin="round" stroke-linecap="round"/>
      ${v.kind ? NPS_EXTRAS[v.kind] : ""}
    </svg>`
}

// Mirror of nps_helper.rb's render_nps_control + the `when "nps"` block of
// _card_component.html.erb. The vertical "liquid container": the step count
// follows the labels (≥2); a card with no usable labels falls back to the
// default 0–10. The container silhouette is themed per Verto (shape).
function npsHtml(opts, shape) {
  const labels = opts.length >= 2 ? opts : DEFAULT_OPTIONS.nps
  const n = Math.max(labels.length, 2)
  const key = NPS_VESSELS[shape] ? shape : "pill"
  const v = NPS_VESSELS[key]
  return `
    <div class="nps-slider"
         data-controller="nps-slider"
         data-nps-slider-steps-value="${n}"
         data-nps-slider-axis-value="vertical"
         data-action="pointerdown->nps-slider#start keydown->nps-slider#key"
         tabindex="0" role="slider"
         aria-valuemin="0" aria-valuemax="${n - 1}">
      <div class="nps-slider-stage">
        <div class="slider-labels nps-slider-labels">
          ${labels.map(o => `<span class="slider-label-text" data-nps-slider-target="label" contenteditable="true">${esc(o)}</span>`).join("")}
        </div>
        <div class="nps-control nps-shape-${key}" style="--nps-aspect: ${v.w} / 340" data-axis="vertical">
          ${npsVesselSvg(key, v)}
          <div class="nps-thumb"><span class="nps-thumb-val"></span></div>
        </div>
      </div>
    </div>`
}

function sliderHtml(opts, ctx = {}) {
  const labels = opts.length ? opts : DEFAULT_OPTIONS.range
  const n = Math.max(labels.length, 2)
  const dots = Array.from({length: n}, (_, i) =>
    `<div class="s-dot" data-slider-target="dot" style="left:${(i / (n - 1) * 100).toFixed(2)}%"></div>`
  ).join("")
  const themes = ctx.rangeThemes || []
  const groups = ctx.rangeThemeGroups || []
  const cur = ctx.rangeTheme || ""
  const bySlug = Object.fromEntries(themes.map(t => [t.slug, t.label]))
  const opt = (s) => `<option value="${esc(s)}"${s === cur ? " selected" : ""}>${esc(bySlug[s] || s)}</option>`
  const optHtml = groups.length
    ? groups.map(g => `<optgroup label="${esc(g.category)}">${g.slugs.map(opt).join("")}</optgroup>`).join("")
    : themes.map(th => opt(th.slug)).join("")
  const picker = themes.length ? `
    <div class="range-theme-picker">
      <label class="range-theme-label">${esc(ctx.rangeThemeLabel || "Animation")}</label>
      <select class="range-theme-select" data-action="change->survey-editor#setRangeTheme">
        ${optHtml}
      </select>
    </div>` : ""
  return `
    <div class="slider-wrap" data-controller="slider" data-slider-steps-value="${n}">
      <div class="slider-track-wrap">
        <div class="slider-track" data-slider-target="track"
             data-action="pointerdown->slider#start">
          ${dots}
          <div class="slider-thumb" data-slider-target="thumb" style="left:50%;">
            <div class="s-line"></div><div class="s-line"></div><div class="s-line"></div>
          </div>
        </div>
      </div>
      <div class="slider-labels">
        ${labels.map(o => `<span class="slider-label-text" contenteditable="true">${esc(o)}</span>`).join("")}
      </div>
    </div>${picker}`
}

export default class extends Controller {
  static targets = [
    "card", "panelEmpty", "cardEditor", "typeList", "panelFooter",
    "panelCardName", "panelHint", "typeOpt", "toast", "toastMsg", "cardCount",
    "allTypesModal", "allTypesList", "allTypeOpt", "modalCardName",
    "subtabs", "subtab", "subview", "tokenSlot", "quizSlot",
    "logicSlot", "branchEmpty", "branchNote", "branchCardName",
    "whyCardName", "whyEmpty", "whyBody", "whyNote", "whyFramework",
    "whyCompetencyRow", "whyCompetencyBadge", "whyCompetencyBlurb",
    "whyOutcomeRow", "whyOutcome",
    "whyConditionRow", "whyConditionBadge", "whyConditionBlurb",
    "panelDeleteBtn"
  ]

  static values = { quiz: Boolean, tokenisation: Boolean, logic: Boolean, defaultLocale: { type: String, default: "en" } }

  // Emoji shown next to each recommended type in the side panel — 1st-4th place.
  RANK_EMOJI = ["🥇", "🥈", "🥉", "⭐"]
  TOP_N      = 4

  activeCardEl = null
  pendingType  = null

  // Quiz/Tokenomics settings for a card live in the .quiz-correct-block /
  // .token-award-block rendered inside it (see _card_component.html.erb) —
  // registerCard() remembers where each card's blocks are by direct element
  // reference (not by position/index, which reordering and deletes would
  // invalidate) so selectCard can relocate the selected card's blocks into
  // the sidebar's Tokenomics/Quiz mode sub-tabs regardless of where they
  // currently sit in the DOM. survey_editor_controller reads/writes them
  // through the same registry so autosave keeps working after relocation.
  connect() {
    this._quizBlocks  = new WeakMap()
    this._tokenBlocks = new WeakMap()
    this._logicBlocks = new WeakMap()
    this.cardTargets.forEach(c => this.registerCard(c))
  }

  registerCard(card) {
    const quiz = card.querySelector(".quiz-correct-block")
    if (quiz) this._quizBlocks.set(card, quiz)
    const tokens = card.querySelector(".token-award-block")
    if (tokens) this._tokenBlocks.set(card, tokens)
    const logic = card.querySelector(".logic-branch-block")
    if (logic) this._logicBlocks.set(card, logic)
  }

  quizBlockFor(card)  { return this._quizBlocks?.get(card) }
  tokenBlockFor(card) { return this._tokenBlocks?.get(card) }
  logicBlockFor(card) { return this._logicBlocks?.get(card) }

  // A hidden holding pen for the previously-active card's relocated blocks —
  // they stay attached to the document (so their inputs/values and Stimulus
  // bindings survive) without being visible anywhere until their card is
  // selected again.
  get _parkingLot() {
    if (!this._parking) {
      this._parking = document.createElement("div")
      this._parking.hidden = true
      this.element.appendChild(this._parking)
    }
    return this._parking
  }

  _parkSlotContents() {
    if (this.hasTokenSlotTarget) this._parkingLot.append(...this.tokenSlotTarget.children)
    if (this.hasQuizSlotTarget)  this._parkingLot.append(...this.quizSlotTarget.children)
    if (this.hasLogicSlotTarget) this._parkingLot.append(...this.logicSlotTarget.children)
  }

  showSubtab(event) {
    this._showSubtab(event.currentTarget.dataset.subtab)
  }

  _showSubtab(name) {
    this.subtabTargets.forEach(b => b.classList.toggle("is-active", b.dataset.subtab === name))
    this.subviewTargets.forEach(v => { v.hidden = v.dataset.subtab !== name })
  }

  // Lazy getter so the JSON blob is read from the current page's DOM on
  // first use, no matter when the module loaded. This avoids both Turbo
  // cache bleed (module-load IIFE saw the previous page) and any
  // connect() lifecycle race with the script tag.
  get typeMeta() {
    if (!this._typeMeta || Object.keys(this._typeMeta).length === 0) {
      this._typeMeta = loadTypeMeta()
    }
    return this._typeMeta
  }

  get eyebrows() {
    if (!this._eyebrows) this._eyebrows = loadEyebrows()
    return this._eyebrows
  }

  // Awareness/Intention/Agency + condition metadata for the Why tab. Lazy +
  // re-readable for the same cache-bleed reason as typeMeta.
  get framework() {
    if (!this._framework || !this._framework.competencies) {
      this._framework = loadFramework()
    }
    return this._framework
  }

  // Verto-themed rating icon, resolved server-side (one source of truth in
  // ApplicationHelper#rating_icon) and exposed on the editor root. Falls back
  // to the classic star so a card switched to "rating" before the attributes
  // exist still renders.
  _ratingIcon() {
    const d = this.element.dataset
    return {
      on:   d.ratingIconOn   || "★",
      off:  d.ratingIconOff  || "☆",
      kind: d.ratingIconKind || "star"
    }
  }

  // Verto-themed NPS container silhouette, resolved server-side
  // (ApplicationHelper#nps_container_shape) and exposed on the editor root.
  // Falls back to the plain pill.
  _npsShape() {
    return this.element.dataset.npsShape || "pill"
  }

  selectCard(event) {
    if (event.target.closest("button[data-action*='deleteCard']")) return

    // If the publish-and-share panel is open, drop back to the answer-type
    // picker so the click reveals the card's edit options.
    this.dispatch("cardSelected")

    const card = event.currentTarget
    this.cardTargets.forEach(c => c.classList.remove("selected"))
    card.classList.add("selected")
    this.activeCardEl = card

    const cardType = card.dataset.cardType
    const cardNum  = card.dataset.cardNum
    this.pendingType = cardType

    const meta = this.typeMeta[cardType]
    this.panelCardNameTarget.textContent = t("editor.card_n", { n: cardNum, type: meta?.badge || cardType })
    this.panelHintTarget.textContent     = t("editor.choose_format")

    this.panelEmptyTarget.style.display = "none"
    this.cardEditorTarget.style.display = "flex"
    this.typeListTarget.style.display    = "flex"
    this.panelFooterTarget.style.display = "flex"
    // The welcome card can't be deleted (mirrors the feed's own chrome row).
    if (this.hasPanelDeleteBtnTarget) this.panelDeleteBtnTarget.hidden = cardType === "welcome_card"

    this._renderCompatibleTypes(cardType)
    this._updateSubtabsFor(card, cardType)
    this._updateBranchFor(card, cardType, cardNum)
    this._renderWhy(card, cardType, cardNum)

    // Paint the pinned sidebar traffic light immediately (it otherwise only
    // repaints on the next markDirty/refreshAll cycle).
    this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")?.refreshCard(card)
  }

  // Show/hide the Tokenomics and Quiz mode sub-tabs for the just-selected
  // card, and relocate its quiz/token blocks (if any) into their slots. Only
  // one card's blocks are ever out of their card at a time — the previously
  // active card's blocks get parked (not lost — see _parkSlotContents).
  _updateSubtabsFor(card, cardType) {
    const isQ = !NON_QUESTION_TYPES.includes(cardType)
    const showTokens = isQ && this.tokenisationValue
    const showQuiz   = isQ && this.quizValue

    const tokensBtn = this.subtabTargets.find(b => b.dataset.subtab === "tokens")
    const quizBtn   = this.subtabTargets.find(b => b.dataset.subtab === "quiz")
    if (tokensBtn) tokensBtn.hidden = !showTokens
    if (quizBtn)   quizBtn.hidden   = !showQuiz
    this.subtabsTarget.hidden = !(showTokens || showQuiz)

    this._parkSlotContents()
    const tokenBlock = showTokens ? this.tokenBlockFor(card) : null
    const quizBlock  = showQuiz   ? this.quizBlockFor(card)  : null
    if (this.hasTokenSlotTarget && tokenBlock) this.tokenSlotTarget.appendChild(tokenBlock)
    if (this.hasQuizSlotTarget && quizBlock)   this.quizSlotTarget.appendChild(quizBlock)

    const activeBtn = this.subtabTargets.find(b => b.classList.contains("is-active"))
    if (!activeBtn || activeBtn.hidden) this._showSubtab("type")
  }

  // Populate the top-level "Branching" tab for the selected card: relocate its
  // routing block (per-answer "go to…" selects + default row) into the panel if
  // the card is a routable single-pick question, otherwise show a note. Mirrors
  // the Tokenomics/Quiz relocation — only one card's block is ever out of its
  // card at a time; the previous one gets parked (see _parkSlotContents).
  _updateBranchFor(card, cardType, cardNum) {
    if (!this.hasLogicSlotTarget) return // logic off ⇒ no Branching panel

    if (this.hasBranchCardNameTarget) {
      const meta = this.typeMeta[cardType]
      this.branchCardNameTarget.textContent = t("editor.card_n", { n: cardNum, type: meta?.badge || cardType })
    }

    const routable = this.logicValue && ROUTABLE_TYPES.includes(cardType)
    this._parkingLot.append(...this.logicSlotTarget.children) // park previous card's block
    const block = routable ? this.logicBlockFor(card) : null
    if (block) this.logicSlotTarget.appendChild(block)

    // .type-panel-empty forces display:flex, so toggle inline display (not the
    // hidden attribute) the same way the Why panel's empty state does.
    if (this.hasBranchEmptyTarget) this.branchEmptyTarget.style.display = "none"       // a card is now selected
    if (this.hasBranchNoteTarget)  this.branchNoteTarget.style.display  = routable ? "none" : "flex" // only for non-routable
  }

  // Populate the "Why" tab for the selected card: the competency it sits under,
  // the plain-language outcome its answers generate, and any enabling condition
  // it measures. Runs on every card select (whichever tab is visible) so
  // switching to Why always reflects the current card.
  _renderWhy(card, cardType, cardNum) {
    if (!this.hasWhyBodyTarget) return

    const fw      = this.framework || {}
    const meta    = this.typeMeta[cardType]
    const comp    = card.dataset.cardCompetency
    const cond    = card.dataset.cardCondition
    const outcome = card.dataset.cardOutcome
    const isQ     = !NON_QUESTION_TYPES.includes(cardType)

    if (this.hasWhyCardNameTarget) {
      this.whyCardNameTarget.textContent = t("editor.card_n", { n: cardNum, type: meta?.badge || cardType })
    }
    if (this.hasWhyEmptyTarget) this.whyEmptyTarget.style.display = "none"
    this.whyBodyTarget.hidden = false

    const compMeta = comp ? fw.competencies?.[comp] : null
    const condMeta = cond ? fw.conditions?.[cond] : null

    if (this.hasWhyCompetencyRowTarget) {
      if (compMeta) {
        this._paintWhyBadge(this.whyCompetencyBadgeTarget, compMeta)
        if (this.hasWhyCompetencyBlurbTarget) this.whyCompetencyBlurbTarget.textContent = compMeta.blurb || ""
      }
      this.whyCompetencyRowTarget.hidden = !compMeta
    }

    if (this.hasWhyOutcomeRowTarget) {
      if (outcome && this.hasWhyOutcomeTarget) this.whyOutcomeTarget.textContent = outcome
      this.whyOutcomeRowTarget.hidden = !outcome
    }

    if (this.hasWhyConditionRowTarget) {
      if (condMeta) {
        this._paintWhyBadge(this.whyConditionBadgeTarget, condMeta)
        if (this.hasWhyConditionBlurbTarget) this.whyConditionBlurbTarget.textContent = condMeta.blurb || ""
      }
      this.whyConditionRowTarget.hidden = !condMeta
    }

    // A note for intro cards (nothing to measure) and for question cards that
    // predate this feature (no Why data stored yet).
    let note = ""
    if (!isQ) note = t("editor.why_intro_card")
    else if (!compMeta && !condMeta && !outcome) note = t("editor.why_unanalysed")
    if (this.hasWhyNoteTarget) {
      this.whyNoteTarget.textContent = note
      this.whyNoteTarget.hidden = !note
    }
    if (this.hasWhyFrameworkTarget) this.whyFrameworkTarget.hidden = !isQ
  }

  // Colour a Why badge from its framework metadata (label + accent hex).
  _paintWhyBadge(el, meta) {
    if (!el) return
    el.textContent = meta.label || ""
    const accent = /^#[0-9a-fA-F]{6}$/.test(meta.accent || "") ? meta.accent : "#01EACB"
    el.style.color = accent
    el.style.borderColor = accent + "66"
    el.style.background = accent + "1f"
  }

  setType(event) {
    const type = event.currentTarget.dataset.type
    this.pendingType = type
    this.typeOptTargets.forEach(o => o.classList.toggle("active", o.dataset.type === type))
  }

  applyType() {
    if (!this.activeCardEl || !this.pendingType) return
    this._applyToCard(this.activeCardEl, this.pendingType)
    this._toast(t("editor.type_updated", { type: this.typeMeta[this.pendingType]?.badge || this.pendingType }))
    this.dispatch("changed")
  }

  openAllTypes() {
    if (!this.activeCardEl) return
    const cardType = this.activeCardEl.dataset.cardType
    const meta = this.typeMeta[cardType]
    if (this.hasModalCardNameTarget) {
      this.modalCardNameTarget.textContent = meta?.badge || cardType
    }
    this._renderAllTypesModal(cardType)
    this.allTypesModalTarget.classList.remove("hidden")
  }

  closeAllTypes() {
    this.allTypesModalTarget.classList.add("hidden")
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  applyTypeFromAll(event) {
    const type = event.currentTarget.dataset.type
    if (!this.activeCardEl || !type) return
    this.pendingType = type
    this._applyToCard(this.activeCardEl, type)
    this._toast(t("editor.type_updated", { type: this.typeMeta[type]?.badge || type }))
    this.dispatch("changed")
    this.closeAllTypes()
  }

  deleteCard(event) {
    event.stopPropagation()
    // The feed's own chrome-row button lives inside the card; the sidebar's
    // pinned button (Answer type panel) doesn't, so it falls back to whichever
    // card is currently selected.
    const card = event.currentTarget.closest("[data-type-panel-target='card']") || this.activeCardEl
    if (!card) return
    if (!window.confirm(t("editor.delete_card_confirm"))) return
    // Remove the whole slot (card + its "Add question" CTA), falling back to the
    // bare card for any context that doesn't use slots.
    ;(card.closest(".card-slot") || card).remove()
    if (card === this.activeCardEl) {
      this.activeCardEl = null
      this.panelEmptyTarget.style.display  = ""
      this.cardEditorTarget.style.display  = "none"
      this.typeListTarget.style.display    = "none"
      this.panelFooterTarget.style.display = "none"
      // The deleted card's blocks (if relocated into the sidebar) go with it —
      // there's no card left to save their data against.
      this._parkSlotContents()
      const tokensBtn = this.subtabTargets.find(b => b.dataset.subtab === "tokens")
      const quizBtn   = this.subtabTargets.find(b => b.dataset.subtab === "quiz")
      if (tokensBtn) tokensBtn.hidden = true
      if (quizBtn)   quizBtn.hidden   = true
      this.subtabsTarget.hidden = true
      this._showSubtab("type")
    }
    this._updateCount()
    this.dispatch("changed")
  }

  // ── private ──────────────────────────────────────────

  _renderCompatibleTypes(cardType) {
    const compat = COMPATIBILITY[cardType] || [{ type: cardType, score: 100, note: "" }]
    // Keep only the top N recommendations, ranked by score descending.
    const ranked = [...compat]
      .sort((a, b) => b.score - a.score)
      .slice(0, this.TOP_N)
    const rankMap = new Map(ranked.map((c, i) => [c.type, { entry: c, rank: i }]))

    // Reorder the DOM so wraps render in rank order (1st → 4th, top to
    // bottom). Without this they stay in CardTypes.pickable order.
    const list = this.typeListTarget
    ranked.forEach(({ type }) => {
      const opt  = this.typeOptTargets.find(o => o.dataset.type === type)
      const wrap = opt?.closest(".type-opt-wrap")
      if (wrap && list) list.appendChild(wrap)
    })

    this.typeOptTargets.forEach(opt => {
      const type  = opt.dataset.type
      const slot  = rankMap.get(type)
      // The tile lives inside a .type-opt-wrap whose left rail holds the
      // medal/star emoji — hide/show the wrap so the rail goes with it.
      const wrap = opt.closest(".type-opt-wrap") || opt

      if (!slot) { wrap.style.display = "none"; return }

      const { entry, rank } = slot
      wrap.style.display = ""
      opt.classList.toggle("active", type === cardType)

      const rankEl = wrap.querySelector(".type-opt-rank")
      if (rankEl) rankEl.textContent = this.RANK_EMOJI[rank] || ""

      opt.querySelector(".type-opt-score")?.remove()
      const badge = document.createElement("div")
      badge.className = "type-opt-score"
      if (type === cardType) {
        badge.textContent = t("editor.current")
        badge.setAttribute("data-primary", "true")
      } else {
        badge.textContent = fitTier(entry.score)
      }
      const radio = opt.querySelector(".type-opt-radio")
      if (radio) radio.before(badge)

      // The contextual note is the explainer now — it surfaces in the ⓘ
      // modal (the panel card itself stays compact, desc is hidden via CSS).
      if (entry.note) {
        const descEl = opt.querySelector(".type-opt-desc")
        if (descEl) descEl.textContent = entry.note
        const infoEl = opt.querySelector(".type-opt-info")
        if (infoEl) infoEl.dataset.typeExplainer = entry.note
      }
    })
  }

  // Modal: sort every pickable type by its fit score for the current card,
  // re-order the DOM, and decorate each tile with a fit-tier badge.
  _renderAllTypesModal(cardType) {
    if (!this.hasAllTypeOptTarget) return
    const compat = COMPATIBILITY[cardType] || []
    const scoreFor = (t) => {
      if (t === cardType) return 101
      const hit = compat.find(c => c.type === t)
      return hit ? hit.score : 0
    }
    const noteFor = (t) => compat.find(c => c.type === t)?.note || ""

    const sorted = [...this.allTypeOptTargets].sort((a, b) =>
      scoreFor(b.dataset.type) - scoreFor(a.dataset.type)
    )
    const list = this.allTypesListTarget || sorted[0]?.parentElement
    sorted.forEach(el => list && list.appendChild(el))

    this.allTypeOptTargets.forEach(opt => {
      const type  = opt.dataset.type
      const score = scoreFor(type)

      opt.classList.toggle("active", type === cardType)

      opt.querySelector(".type-opt-score")?.remove()
      const badge = document.createElement("div")
      badge.className = "type-opt-score"
      if (type === cardType) {
        badge.textContent = t("editor.current")
        badge.setAttribute("data-primary", "true")
      } else {
        badge.textContent = score > 0 ? fitTier(score) : t("editor.off_brief")
      }
      const row = opt.querySelector(".type-opt-row > div[style]")
      if (row) row.parentElement.appendChild(badge)

      const note = noteFor(type)
      if (note) {
        const descEl = opt.querySelector(".type-opt-desc")
        if (descEl) descEl.textContent = note
        const infoEl = opt.querySelector(".type-opt-info")
        if (infoEl) infoEl.dataset.typeExplainer = note
      }
    })
  }


  _applyToCard(card, type) {
    const meta = this.typeMeta[type]
    if (!meta) return

    const wasType = card.dataset.cardType

    // The scenario book widget needs its right panel to join the flex-column
    // fill chain (see .split-right--book in application.css) — the server
    // only adds this class on initial render, so a client-side type switch
    // has to toggle it itself or the book silently sits at its min-height.
    const splitRight = card.querySelector(".split-right")
    if (splitRight) splitRight.classList.toggle("split-right--book", type === "scenario")

    // 1. Update badge + eyebrow
    const badge = card.querySelector(".s-badge")
    if (badge) { badge.textContent = meta.badge; badge.className = `s-badge ${meta.css}` }

    const eyebrow = card.querySelector(".q-eyebrow")
    if (eyebrow) {
      eyebrow.textContent = (this.eyebrows[this.defaultLocaleValue] || {})[type] || meta.eyebrow
    }

    // 2. Swap the interactive component HTML on the RIGHT panel
    const slot = card.querySelector("[data-card-component]")
    if (slot) {
      const opts = this._optionsFor(card, type)
      const builder = COMPONENTS[type] || (() => "")
      slot.innerHTML = builder(opts, {
        ratingIcon:      this._ratingIcon(),
        npsShape:        this._npsShape(),
        rangeThemes:     this._rangeThemePicker.themes,
        rangeThemeGroups: this._rangeThemePicker.groups,
        rangeThemeLabel: this._rangeThemePicker.label,
        rangeTheme:      card.dataset.cardRangeTheme || "",
        pages:           this._pagesFor(card, type)
      })
    }

    card.dataset.cardType = type

    // The "Other" block applies to question types only.
    const otherBlock = card.querySelector(".other-block")
    if (otherBlock) otherBlock.hidden = NON_QUESTION_TYPES.includes(type)

    // 3. Swap LEFT panel when entering or leaving Range — Range shows the
    //    reactive Lottie that other types don't, and other types need the
    //    design-prompt / image chrome that the Lottie suppresses.
    if (type === "range" && wasType !== "range") {
      this._mountNpsLottie(card)
    } else if (wasType === "range" && type !== "range") {
      this._unmountNpsLottie(card)
    }

    if (card === this.activeCardEl) {
      const num = card.dataset.cardNum
      this.panelCardNameTarget.textContent = t("editor.card_n", { n: num, type: meta.badge })
      this._renderCompatibleTypes(type)
      this.pendingType = type
    }
  }

  // ── NPS left-panel mount/unmount ─────────────────────────
  // The Lottie URLs blob is rendered once per page (see show.html.erb) so
  // we can mount the lottie-player without going back to the server when a
  // card is switched to NPS. CSS (`.split-left:has(.nps-lottie) > …`)
  // handles hiding the image / design-prompt chrome while the Lottie
  // is mounted.

  get _npsLottieUrls() {
    if (this.__npsLottieUrls) return this.__npsLottieUrls
    try {
      const raw = document.getElementById("nps-lottie-urls")?.textContent || "[]"
      this.__npsLottieUrls = JSON.parse(raw)
    } catch (_) {
      this.__npsLottieUrls = []
    }
    return this.__npsLottieUrls
  }

  // Range-card theme picker blob (label + [{slug,label,urls}]). Read once.
  get _rangeThemePicker() {
    if (this.__rangeThemePicker) return this.__rangeThemePicker
    let data = {}
    try { data = JSON.parse(document.getElementById("range-theme-picker")?.textContent || "{}") } catch (_) {}
    data.themes = data.themes || []
    data.groups = data.groups || []
    data.label = data.label || "Animation"
    this.__rangeThemePicker = data
    return data
  }

  _mountNpsLottie(card) {
    const left = card.querySelector(".split-left")
    if (!left || left.querySelector(".nps-lottie")) return
    // Honour the card's chosen theme; fall back to the default basketball set.
    const theme = card.dataset.cardRangeTheme || ""
    const urls = this._rangeThemePicker.themes.find(th => th.slug === theme)?.urls || this._npsLottieUrls
    if (!urls.length) return

    const wrap = document.createElement("div")
    wrap.className = "nps-lottie"
    wrap.dataset.controller = "lottie-player"
    wrap.dataset.lottiePlayerUrlsValue = JSON.stringify(urls)
    wrap.dataset.lottiePlayerCurrentValue = "1"

    const mount = document.createElement("div")
    mount.className = "nps-lottie-mount"
    mount.dataset.lottiePlayerTarget = "mount"
    wrap.appendChild(mount)

    // Position above .panel-progress so the Lottie sits behind the progress
    // bar exactly like the server-rendered version does.
    left.insertBefore(wrap, left.firstChild)
  }

  _unmountNpsLottie(card) {
    const left = card.querySelector(".split-left")
    const wrap = left && left.querySelector(".nps-lottie")
    if (wrap) wrap.remove() // lottie-player controller's disconnect() destroys the lottie instance
  }

  _optionsFor(card, type) {
    let original = []
    try { original = JSON.parse(card.dataset.cardOptions || "[]") } catch (_) {}
    if (type === "yes_no") return ["Yes", "No"]
    if (original.length) return original
    return DEFAULT_OPTIONS[type] || []
  }

  // Existing pages if this card already had some (switching away from
  // Scenario and back preserves what was written), else a fresh blank page.
  _pagesFor(card, type) {
    if (type !== "scenario") return []
    let original = []
    try { original = JSON.parse(card.dataset.cardPages || "[]") } catch (_) {}
    if (Array.isArray(original) && original.length) return original
    return DEFAULT_PAGES.scenario || []
  }

  _updateCount() {
    if (!this.hasCardCountTarget) return
    const n = this.cardTargets.length
    this.cardCountTarget.textContent = t("editor.cards_count", { n })
  }

  _toast(msg) {
    this.toastMsgTarget.textContent = msg
    this.toastTarget.classList.add("show")
    setTimeout(() => this.toastTarget.classList.remove("show"), 2200)
  }
}
