import { Controller } from "@hotwired/stimulus"

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
  range: [
    { type: "range",            score: 100, note: "Best at capturing strength of feeling — gives you a clean distribution to read insight from." },
    { type: "rating",           score: 85,  note: "Similar shape, but stars are more familiar and a touch less expressive." },
    { type: "tap_card",         score: 50,  note: "Trades the scale for a yes/no per statement — more engaging, less granular." },
    { type: "yes_no",           score: 30,  note: "Strips the scale to two answers — most data goes with it. Only use if the binary is the insight." },
  ],
  rating: [
    { type: "rating",           score: 100, note: "Star scale is instantly understood and gives a comparable score across questions." },
    { type: "range",            score: 85,  note: "More expressive scale with custom endpoints — better when the spectrum isn't generic 'good/bad'." },
    { type: "tap_card",         score: 50,  note: "Loses the scale, but more engaging if you want a quick gut take across several items." },
    { type: "select_one_grid",  score: 35,  note: "Flattens the scale into discrete labelled tiles — loses the smoothness people respond to in stars." },
  ],
  yes_no: [
    { type: "yes_no",           score: 100, note: "Crisp signal when you genuinely need a binary — easy to read and easy to answer." },
    { type: "select_one_grid",  score: 75,  note: "Adds nuance with a few defined visual options — better when 'yes/no' is hiding the real answer." },
    { type: "range",            score: 45,  note: "Captures the strength of the yes or no — useful when degree matters more than the answer." },
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

// Left-panel illustrations explaining HOW to interact with each type
const ILLUSTRATIONS = {
  range: () => `
    <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:10px;">
      <div style="display:flex;align-items:center;gap:8px;color:rgba(255,255,255,0.9);">
        <span style="font-size:16px;opacity:0.5;">←</span>
        <div style="position:relative;flex:1;height:6px;border-radius:3px;background:rgba(255,255,255,0.15);">
          <div style="position:absolute;width:40%;height:100%;border-radius:3px;background:#01EACB;"></div>
          <div style="position:absolute;left:38%;top:50%;transform:translate(-50%,-50%);width:28px;height:28px;border-radius:50%;background:white;box-shadow:0 2px 8px rgba(0,0,0,0.3);display:flex;align-items:center;justify-content:center;">
            <svg width="10" height="10" viewBox="0 0 10 10"><path d="M3 5H1m6 0H9M5 3V1m0 8V7" stroke="#01EACB" stroke-width="1.5" stroke-linecap="round"/></svg>
          </div>
        </div>
        <span style="font-size:16px;opacity:0.5;">→</span>
      </div>
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;text-align:center;">Drag the slider to your answer</div>
    </div>`,

  rating: () => `
    <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:12px;">
      <div style="display:flex;gap:8px;">
        ${[0,1,2,3,4].map(i =>
          `<span style="font-size:34px;line-height:1;${i<3?"color:#FFCC00;":"color:rgba(255,255,255,0.2);"}">
            ${i<3?"★":"☆"}
          </span>`
        ).join("")}
      </div>
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;text-align:center;">Tap a star to rate</div>
    </div>`,

  multiple_choice: () => `
    <div style="width:80%;display:flex;flex-direction:column;gap:6px;">
      ${[["A",SWIPE_FILLS[0],true],["B",SWIPE_FILLS[1],false],["C",SWIPE_FILLS[2],false]].map(([label,[a,b],sel]) =>
        `<div style="display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:8px;${sel?"background:rgba(1,234,203,0.15);outline:1px solid rgba(1,234,203,0.5);":""}">
          <div style="width:22px;height:22px;border-radius:6px;flex-shrink:0;background:linear-gradient(135deg,${a},${b});box-shadow:0 1px 3px rgba(0,0,0,0.25);"></div>
          <span style="flex:1;font-size:12px;font-family:'Alata',sans-serif;${sel?"color:#01EACB":"color:rgba(255,255,255,0.7)"}">Option ${label}</span>
          ${sel?`<span style="color:#01EACB;font-size:11px;font-weight:700;">✓</span>`:""}
        </div>`
      ).join("")}
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;margin-top:4px;text-align:center;">Tap one option to select</div>
    </div>`,

  select_many: () => `
    <div style="width:80%;display:flex;flex-direction:column;gap:6px;">
      ${[["A",SWIPE_FILLS[0],true],["B",SWIPE_FILLS[1],true],["C",SWIPE_FILLS[2],false]].map(([label,[a,b],sel]) =>
        `<div style="display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:8px;${sel?"background:rgba(1,234,203,0.12);outline:1px solid rgba(1,234,203,0.45);":""}">
          <div style="width:22px;height:22px;border-radius:6px;flex-shrink:0;background:linear-gradient(135deg,${a},${b});box-shadow:0 1px 3px rgba(0,0,0,0.25);"></div>
          <span style="flex:1;font-size:12px;font-family:'Alata',sans-serif;${sel?"color:#01EACB":"color:rgba(255,255,255,0.7)"}">Option ${label}</span>
          ${sel?`<span style="color:#01EACB;font-size:11px;font-weight:700;">✓</span>`:""}
        </div>`
      ).join("")}
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;margin-top:4px;text-align:center;">Tap all that apply</div>
    </div>`,

  yes_no: () => `
    <div style="width:80%;display:flex;flex-direction:column;gap:6px;">
      ${[["Yes", ["#d4edda","#a8d5b5"], true], ["No", ["#f8d7da","#f5a8b0"], false]].map(([label,[a,b],sel]) =>
        `<div style="display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:8px;${sel?"background:rgba(1,234,203,0.15);outline:1px solid rgba(1,234,203,0.5);":""}">
          <div style="width:22px;height:22px;border-radius:6px;flex-shrink:0;background:linear-gradient(135deg,${a},${b});box-shadow:0 1px 3px rgba(0,0,0,0.25);"></div>
          <span style="flex:1;font-size:12px;font-family:'Alata',sans-serif;${sel?"color:#01EACB":"color:rgba(255,255,255,0.7)"}">${label}</span>
          ${sel?`<span style="color:#01EACB;font-size:11px;font-weight:700;">✓</span>`:""}
        </div>`
      ).join("")}
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;margin-top:4px;text-align:center;">Tap to choose one</div>
    </div>`,

  select_one_grid: () => `
    <div style="width:80%;display:flex;flex-direction:column;gap:8px;">
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;">
        ${[["A","#d4edda",true],["B","#d1ecf1",false],["C","#fff3cd",false],["D","#f8d7da",false]].map(([l,bg,sel]) =>
          `<div style="position:relative;height:44px;border-radius:8px;background:${bg};display:flex;align-items:center;justify-content:center;${sel?"outline:2px solid #01EACB;outline-offset:-2px;":""}">
            <span style="font-size:11px;color:rgba(0,0,0,0.55);font-family:'Alata',sans-serif;">${l}</span>
            ${sel?`<div style="position:absolute;top:3px;right:4px;color:#01EACB;font-size:10px;font-weight:700;">✓</div>`:""}
          </div>`
        ).join("")}
      </div>
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;text-align:center;">Tap one image to select</div>
    </div>`,

  select_many_grid: () => `
    <div style="width:80%;display:flex;flex-direction:column;gap:8px;">
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;">
        ${[["A","#d4edda",true],["B","#d1ecf1",true],["C","#fff3cd",false],["D","#f8d7da",false]].map(([l,bg,sel]) =>
          `<div style="position:relative;height:44px;border-radius:8px;background:${bg};display:flex;align-items:center;justify-content:center;${sel?"outline:2px solid #01EACB;outline-offset:-2px;":""}">
            <span style="font-size:11px;color:rgba(0,0,0,0.55);font-family:'Alata',sans-serif;">${l}</span>
            ${sel?`<div style="position:absolute;top:3px;right:4px;color:#01EACB;font-size:10px;font-weight:700;">✓</div>`:""}
          </div>`
        ).join("")}
      </div>
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;text-align:center;">Tap all that apply</div>
    </div>`,

  tap_card: () => `
    <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:10px;">
      <div style="position:relative;height:72px;width:100%;">
        <div style="position:absolute;left:4px;top:8px;width:70%;height:58px;border-radius:12px;background:rgba(255,255,255,0.06);transform:rotate(-4deg);"></div>
        <div style="position:absolute;left:8px;top:4px;width:72%;height:58px;border-radius:12px;background:rgba(255,255,255,0.10);transform:rotate(-2deg);"></div>
        <div style="position:absolute;left:12px;top:0;width:74%;height:60px;border-radius:12px;background:rgba(255,255,255,0.88);display:flex;align-items:center;justify-content:center;">
          <span style="font-size:11px;color:rgba(0,0,0,0.5);font-family:'ABeeZee',sans-serif;">Statement to react to</span>
        </div>
      </div>
      <div style="display:flex;justify-content:space-between;width:90%;font-size:11px;">
        <span style="color:#e05555;font-family:'Alata',sans-serif;">← No</span>
        <span style="color:#01EACB;font-family:'Alata',sans-serif;">Yes →</span>
      </div>
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;text-align:center;">Swipe cards left or right</div>
    </div>`,

  open_ended: () => `
    <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:10px;">
      <div style="width:100%;border:1px solid rgba(255,255,255,0.2);border-radius:10px;padding:10px 12px;background:rgba(255,255,255,0.04);">
        <div style="font-size:11px;color:rgba(255,255,255,0.3);font-family:'ABeeZee',sans-serif;">Type your answer…</div>
        <div style="height:2px;width:6px;background:#01EACB;margin-top:6px;border-radius:2px;"></div>
      </div>
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;text-align:center;">Tap and type your response</div>
    </div>`,

  welcome_card: () => `
    <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:12px;">
      <div style="font-size:40px;line-height:1;">👋</div>
      <div style="color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;text-align:center;line-height:1.4;">Read the intro — no answer needed</div>
    </div>`,
}

const DEFAULT_OPTIONS = {
  range:            ["Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree"],
  rating:           ["Poor", "Fair", "Good", "Great", "Excellent"],
  multiple_choice:  ["Option A", "Option B", "Option C"],
  select_many:      ["Option A", "Option B", "Option C", "Option D"],
  yes_no:           ["Yes", "No"],
  select_one_grid:  ["A", "B", "C", "D"],
  select_many_grid: ["A", "B", "C", "D"],
  tap_card:         ["Statement 1", "Statement 2", "Statement 3"],
  open_ended:       [],
  welcome_card:     [],
}

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
  if (score >= 100) return "Best fit"
  if (score >= 80)  return "Strong alternative"
  if (score >= 60)  return "Solid alternative"
  if (score >= 40)  return "Workable"
  return "Use sparingly"
}

// HTML builders for the right-side interactive component on each card
const COMPONENTS = {
  multiple_choice: (opts) => choiceListHtml(opts, "single"),
  select_many:     (opts) => choiceListHtml(opts, "multi"),

  yes_no: () => `
    <ul class="choice-list" data-controller="picker" data-picker-mode-value="single">
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

  range: (opts) => sliderHtml(opts),

  rating: (opts) => {
    const labels = opts.length >= 2 ? opts : ["Poor", "Fair", "Good", "Great", "Excellent"]
    const first  = labels[0] || "Poor"
    const last   = labels[labels.length - 1] || "Excellent"
    return `
      <div class="rating-wrap" data-controller="rating">
        <div class="rating-stars">
          ${[0,1,2,3,4].map(i => `
            <span class="rating-star"
                  data-rating-target="star"
                  data-rating-index="${i}"
                  data-action="click->rating#pick mouseover->rating#hover mouseout->rating#unhover">☆</span>
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

function choiceListHtml(opts, mode) {
  const tick = mode === "multi" ? "pick-square" : "pick-dot"
  return `
    <ul class="choice-list" data-controller="picker card-editor"
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
    <ul class="choice-grid choice-grid-${cols}" data-controller="picker"
        data-picker-mode-value="${mode}">
      ${opts.map((o,i) => `
        <li class="choice-card" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false">
          <div class="choice-card-bg choice-bg-${(i % 6) + 1}"></div>
          <div class="choice-overlay"></div>
          <div class="choice-tick">✓</div>
          <div class="choice-label" contenteditable="true">${esc(o)}</div>
        </li>`).join("")}
    </ul>`
}

function sliderHtml(opts) {
  const labels = opts.length ? opts : DEFAULT_OPTIONS.range
  const n = Math.max(labels.length, 2)
  const dots = Array.from({length: n}, (_, i) =>
    `<div class="s-dot" data-slider-target="dot" style="left:${(i / (n - 1) * 100).toFixed(2)}%"></div>`
  ).join("")
  return `
    <div class="slider-wrap" data-controller="slider" data-slider-steps-value="${n}">
      <div class="slider-track-wrap">
        <div class="slider-tooltip" data-slider-target="tooltip" style="left:50%;">
          <span class="slider-tooltip-text" data-slider-target="tooltipText"></span>
        </div>
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
    </div>`
}

export default class extends Controller {
  static targets = [
    "card", "panelEmpty", "typeList", "panelFooter",
    "panelCardName", "panelHint", "typeOpt", "toast", "toastMsg", "cardCount",
    "allTypesModal", "allTypesList", "allTypeOpt", "modalCardName"
  ]

  // Emoji shown next to each recommended type in the side panel — 1st-4th place.
  RANK_EMOJI = ["🥇", "🥈", "🥉", "⭐"]
  TOP_N      = 4

  activeCardEl = null
  pendingType  = null

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
    this.panelCardNameTarget.textContent = `Card ${cardNum} · ${meta?.badge || cardType}`
    this.panelHintTarget.textContent     = "Choose an answer format below."

    this.panelEmptyTarget.style.display  = "none"
    this.typeListTarget.style.display    = "flex"
    this.panelFooterTarget.style.display = "flex"

    this._renderCompatibleTypes(cardType)
  }

  setType(event) {
    const type = event.currentTarget.dataset.type
    this.pendingType = type
    this.typeOptTargets.forEach(o => o.classList.toggle("active", o.dataset.type === type))
  }

  applyType() {
    if (!this.activeCardEl || !this.pendingType) return
    this._applyToCard(this.activeCardEl, this.pendingType)
    this._toast(`Answer type updated to ${this.typeMeta[this.pendingType]?.badge || this.pendingType}`)
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
    this._toast(`Answer type updated to ${this.typeMeta[type]?.badge || type}`)
    this.dispatch("changed")
    this.closeAllTypes()
  }

  deleteCard(event) {
    event.stopPropagation()
    const card = event.currentTarget.closest("[data-type-panel-target='card']")
    if (!card) return
    card.remove()
    if (card === this.activeCardEl) {
      this.activeCardEl = null
      this.panelEmptyTarget.style.display  = ""
      this.typeListTarget.style.display    = "none"
      this.panelFooterTarget.style.display = "none"
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
        badge.textContent = "Current"
        badge.setAttribute("data-primary", "true")
      } else {
        badge.textContent = fitTier(entry.score)
      }
      const radio = opt.querySelector(".type-opt-radio")
      if (radio) radio.before(badge)

      const descEl = opt.querySelector(".type-opt-desc")
      if (descEl && entry.note) descEl.textContent = entry.note
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
        badge.textContent = "Current"
        badge.setAttribute("data-primary", "true")
      } else {
        badge.textContent = score > 0 ? fitTier(score) : "Off-brief"
      }
      const row = opt.querySelector(".type-opt-row > div[style]")
      if (row) row.parentElement.appendChild(badge)

      const descEl = opt.querySelector(".type-opt-desc")
      const note = noteFor(type)
      if (descEl && note) descEl.textContent = note
    })
  }


  _applyToCard(card, type) {
    const meta = this.typeMeta[type]
    if (!meta) return

    // 1. Update badge + eyebrow
    const badge = card.querySelector(".s-badge")
    if (badge) { badge.textContent = meta.badge; badge.className = `s-badge ${meta.css}` }

    const eyebrow = card.querySelector(".q-eyebrow")
    if (eyebrow) eyebrow.textContent = meta.eyebrow

    // 2. Swap the interactive component HTML
    const slot = card.querySelector("[data-card-component]")
    if (slot) {
      const opts = this._optionsFor(card, type)
      const builder = COMPONENTS[type] || (() => "")
      slot.innerHTML = builder(opts)
    }

    // 3. Swap the left-panel illustration
    const illus = card.querySelector("[data-card-illustration]")
    if (illus) {
      const fn = ILLUSTRATIONS[type] || ILLUSTRATIONS.welcome_card
      illus.innerHTML = fn()
    }

    card.dataset.cardType = type

    if (card === this.activeCardEl) {
      const num = card.dataset.cardNum
      this.panelCardNameTarget.textContent = `Card ${num} · ${meta.badge}`
      this._renderCompatibleTypes(type)
      this.pendingType = type
    }
  }

  _optionsFor(card, type) {
    let original = []
    try { original = JSON.parse(card.dataset.cardOptions || "[]") } catch (_) {}
    if (type === "yes_no") return ["Yes", "No"]
    if (original.length) return original
    return DEFAULT_OPTIONS[type] || []
  }

  _updateCount() {
    if (!this.hasCardCountTarget) return
    const n = this.cardTargets.length
    this.cardCountTarget.textContent = `${n} card${n !== 1 ? "s" : ""}`
  }

  _toast(msg) {
    this.toastMsgTarget.textContent = msg
    this.toastTarget.classList.add("show")
    setTimeout(() => this.toastTarget.classList.remove("show"), 2200)
  }
}
