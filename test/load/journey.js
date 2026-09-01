// k6 load-test: the real respondent journey against the LoadTestSeeder Verto.
//
//   k6 run -e BASE_URL=https://<scratch-host> -e TOKEN=<publish_token> test/load/journey.js
//
// NEVER point BASE_URL at production. See test/load/README.md for the full
// procedure, the guardrails, and what to record from each run.
//
// Env knobs (all optional beyond BASE_URL/TOKEN):
//   ARRIVALS_PER_S  peak respondent arrivals per second        (default 10; event target 83, proof 125)
//   RAMP_S          seconds ramping 0 -> peak                  (default 60)
//   HOLD_S          seconds holding peak                       (default 300)
//   DWELL_SCALE     multiplier on think-time sleeps            (default 0.05 => ~14s/journey)
//                   1.0 approximates a real ~4-5 min dwell; use it for the
//                   final rehearsal (needs ~25k VUs at 83/s — a big runner).
//   BROWNOUT=1      adds a scenario replaying submits in quick triples, the
//                   shape the service worker's drain queue produces after a
//                   5xx brownout. Watch that the echo stays bounded.
//
// The answers below match LoadTestSeeder::CARDS by index — change one file,
// change the other.

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Counter } from "k6/metrics";

const BASE = __ENV.BASE_URL;
const TOKEN = __ENV.TOKEN;
if (!BASE || !TOKEN) throw new Error("BASE_URL and TOKEN are required");
if (/playverto\.com|survey-poc\.onrender\.com/.test(BASE) && __ENV.I_KNOW_THIS_IS_NOT_PROD !== "1") {
  throw new Error("BASE_URL looks like production. Refusing.");
}

const ARRIVALS = Number(__ENV.ARRIVALS_PER_S || 10);
const RAMP_S = Number(__ENV.RAMP_S || 60);
const HOLD_S = Number(__ENV.HOLD_S || 300);
const DWELL = Number(__ENV.DWELL_SCALE || 0.05);

const play = `${BASE}/play/${TOKEN}`;
const journeyTime = new Trend("journey_duration", true);

// Status-class counters, because the end-of-run summary only says "failed",
// not WHO failed the request — a 429 from the app, a 403 from an edge
// protection layer, and a network error are three different diagnoses.
const status2xx = new Counter("status_2xx");
const status429 = new Counter("status_429");
const status403 = new Counter("status_403");
const status4xx = new Counter("status_4xx_other");
const status5xx = new Counter("status_5xx");
const statusNet = new Counter("status_network_error");

function note(res, endpoint) {
  if (res.status >= 200 && res.status < 400) status2xx.add(1);
  else if (res.status === 429) status429.add(1);
  else if (res.status === 403) status403.add(1);
  else if (res.status >= 500) status5xx.add(1);
  else if (res.status >= 400) status4xx.add(1);
  else statusNet.add(1);
  // A thin sample of failure bodies — enough to identify the responder
  // (our JSON error vs an edge HTML page) without flooding the log.
  if (res.status !== 200 && (__VU % 40) === 1 && __ITER === 0) {
    const body = String(res.body || "").replace(/\s+/g, " ").slice(0, 160);
    console.log(`[diag] ${endpoint} status=${res.status} server=${res.headers["Server"] || "?"} cf-ray=${res.headers["Cf-Ray"] || "-"} retry-after=${res.headers["Retry-After"] || "-"} body: ${body}`);
  }
  return res;
}

export const options = {
  scenarios: {
    journey: {
      executor: "ramping-arrival-rate",
      startRate: 0,
      timeUnit: "1s",
      preAllocatedVUs: Math.max(50, Math.ceil(ARRIVALS * (DWELL >= 1 ? 320 : 20))),
      maxVUs: Math.max(200, Math.ceil(ARRIVALS * (DWELL >= 1 ? 340 : 40))),
      stages: [
        { duration: `${RAMP_S}s`, target: ARRIVALS },
        { duration: `${HOLD_S}s`, target: ARRIVALS },
        { duration: "30s", target: 0 },
      ],
      exec: "journey",
    },
    ...(__ENV.BROWNOUT === "1" && {
      retry_echo: {
        executor: "constant-arrival-rate",
        rate: Math.max(1, Math.ceil(ARRIVALS / 4)),
        timeUnit: "1s",
        duration: `${RAMP_S + HOLD_S}s`,
        preAllocatedVUs: 50,
        maxVUs: 200,
        exec: "retryEcho",
      },
    }),
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{endpoint:show}": ["p(95)<1500"],
    "http_req_duration{endpoint:progress}": ["p(95)<1000"],
    "http_req_duration{endpoint:submit}": ["p(95)<1000"],
    "http_req_duration{endpoint:leaderboard}": ["p(95)<1000"],
  },
};

const JSON_HEADERS = { "Content-Type": "application/json" };

function sessionToken() {
  return `k6-${__VU}-${__ITER}-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
}

function answers(i) {
  return {
    "1": { type: "multiple_choice", value: ["Email", "Social", "Friend", "Other"][i % 4] },
    "2": { type: "rating", value: 1 + (i % 5) },
    "3": { type: "multiple_choice", value: ["Red", "Green", "Blue"][i % 3] },
    "4": { type: "open_ended", value: `k6 answer ${i % 17}` },
    "5": { type: "rating", value: 1 + ((i + 2) % 5) },
  };
}

function payload(session, ans, playerKey) {
  return JSON.stringify({ session_token: session, answers: ans, locale: "en", player_key: playerKey });
}

export function journey() {
  const started = Date.now();
  const session = sessionToken();
  const playerKey = `k6-player-${__VU}-${__ITER}`;
  const i = __VU * 1000 + __ITER;

  // 1. The page + PWA fetches (the dynamic requests; /assets belong to the CDN).
  const page = note(http.get(play, { tags: { endpoint: "show" } }), "show");
  check(page, { "show 200": (r) => r.status === 200 });
  note(http.get(`${play}/manifest`, { tags: { endpoint: "manifest" } }), "manifest");
  note(http.get(`${BASE}/service-worker`, { tags: { endpoint: "service_worker" } }), "service_worker");
  sleep(60 * DWELL);

  // 2. Consent.
  const consent = note(http.post(`${play}/consent`, JSON.stringify({ session_token: session, agreed: true }),
    { headers: JSON_HEADERS, tags: { endpoint: "consent" } }), "consent");
  check(consent, { "consent ok": (r) => r.status === 200 });
  sleep(30 * DWELL);

  // 3. One mid-survey progress save (fires once per respondent — verified
  //    against player_controller.js's _registered guard).
  const partial = answers(i);
  const midway = { "1": partial["1"], "2": partial["2"] };
  const progress = note(http.post(`${play}/progress`, payload(session, midway, playerKey),
    { headers: JSON_HEADERS, tags: { endpoint: "progress" } }), "progress");
  check(progress, { "progress ok": (r) => r.status === 200 });
  sleep(120 * DWELL);

  // 4. Submit the full deck.
  const submit = note(http.post(`${play}/submit`, payload(session, partial, playerKey),
    { headers: JSON_HEADERS, tags: { endpoint: "submit" } }), "submit");
  check(submit, { "submit ok": (r) => r.status === 200 });
  sleep(5 * DWELL);

  // 5. The auto-fired leaderboard on the thank-you screen.
  const lb = note(http.get(`${play}/leaderboard?session_token=${session}&player_key=${encodeURIComponent(playerKey)}`,
    { tags: { endpoint: "leaderboard" } }), "leaderboard");
  check(lb, {
    "leaderboard 200": (r) => r.status === 200,
    "leaderboard has entries": (r) => {
      try { return Array.isArray(r.json().entries); } catch (_) { return false; }
    },
  });

  journeyTime.add(Date.now() - started);
}

// The service worker's drain replays a queued submit as fast as page activity
// allows — model it as the same submit fired three times back-to-back.
export function retryEcho() {
  const session = sessionToken();
  const body = payload(session, answers(__ITER), null);
  for (let n = 0; n < 3; n++) {
    note(http.post(`${play}/submit`, body, { headers: JSON_HEADERS, tags: { endpoint: "retry_echo" } }), "retry_echo");
  }
}
