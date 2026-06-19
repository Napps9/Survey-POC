# Playverto — Platform Update for the CEO

**Period:** Past two weeks (5–19 June 2026; active development 11–19 June)
**Product:** Playverto — the *Verto* survey platform (creators build Vertos; the public plays them at a shareable link)

---

## Bottom line

In the last two weeks we shipped **four new headline capabilities** — interactive Quizzes, AI-written results reports, a survey-quality "coach," and an internal analytics suite — while also **closing a serious security hole, hardening the platform, and ending the out-of-memory crashes** that were causing production errors. Alongside this, the respondent and creator experiences were substantially polished, especially on mobile.

Throughput for the period: **52 distinct updates, ~11,200 lines of change across 158 files, over 9 active days.**

---

## 1. New capabilities (expand what the product can do and sell)

- **Quiz mode** — Vertos can now be run as graded quizzes: answers are scored and respondents see *"how you compare"* against everyone else. This turns the platform from pure data-collection into an interactive, shareable experience.

- **AI-generated results reports** — From any Verto's results, a creator can now generate a written report with AI. It **streams into the screen live as it's written**, and can be **downloaded as a PDF or saved straight to Google Drive**. This removes the manual "make sense of the data" step that previously sat with the customer.

- **"Rules of the Game" quality scoring** — Every Verto and every individual question now gets a **traffic-light quality score** (red/amber/green) with a plain-English breakdown of what to fix. A one-click **"Optimise" button uses AI to fix a flagged question automatically.** This helps customers produce higher-quality surveys without expert help — and nudges them toward better response rates.

- **Internal analytics & business intelligence** — We stood up a **staff-only analytics suite** (SQL-backed dashboards over our live data) so we can answer business questions directly. Shipped reports include **weekly creator-retention cohorts** and full **questions-and-answers exploration** per Verto. Internal/test organisations are filtered out so the numbers reflect real customers.

## 2. A better experience for respondents (the people who *play* a Verto)

- **Mobile & tablet redesign** — Rebuilt the player layout for phones and tablets (fixed broken/overflowing layouts, cleaner image handling, added **haptic feedback** and improved legibility). The respondent experience is where drop-off happens, so this directly protects completion rates.
- **Consent gate** — Editable consent text with an **"Agree to continue" step before the first question** — important for data-protection compliance.
- **Required questions** — Creators can mark questions as required, and the player now enforces it.
- **Regional comparison** — Respondents can see how their region compares, including a **world-map comparison view** — a core differentiator of the product.
- **Shareable thank-you screen** — Custom closing message with a **Share button and a forward-to-your-website link** — a built-in growth/virality loop at the end of every Verto.

## 3. A smoother experience for creators (the people who *build* a Verto)

- **Reworked creation wizard** — Clearer audience-targeting step, regional targeting, a guided naming step, and the ability to **import questions directly from a PDF** brief.
- **In-editor device previews** — Creators can preview their Verto framed as a phone or tablet, with clearer question-type guidance and controls.
- **Collaboration ("Collective Impact")** — Renamed Alliances to **Collective Impact** and enabled organisations to **share a common set of questions** across a group — supporting multi-org/benchmarking use cases.
- **Publish safeguards** — Once a Verto is live it becomes **read-only**, and creators are warned before publishing — protecting the integrity of data already being collected.

## 4. Onboarding

- **One-click Google sign-in** — Added social sign-in via Google to lower the barrier to getting started. (We evaluated Microsoft and Apple as well, then deliberately narrowed to Google to keep onboarding simple.)

## 5. Security, reliability & compliance (risk reduction)

- **Closed an account-takeover vulnerability** in the invite flow, removed a hard-coded seed credential, and applied a broad security-hardening pass.
- **Platform hardening** — Added an enforcing Content-Security-Policy, request **rate limiting**, stricter logo-upload validation, and stopped raw error details from ever reaching end users.
- **Ended the production crashes** — Eliminated the out-of-memory errors (502s) that were taking pages down under load, and fixed a results-page failure and several mobile layout bugs.

---

## How to read this

Items 1 and 2 are the ones worth leading with externally — Quizzes, AI reports, and the quality coach are net-new, demonstrable capabilities. Item 5 is the "we also reduced our risk" story for the board: a real security vulnerability was found and fixed, and the platform is now meaningfully more stable and compliant than it was two weeks ago.

*Prepared 19 June 2026.*
