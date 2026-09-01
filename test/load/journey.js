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
import { Trend } from "k6/metrics";

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
  const page = http.get(play, { tags: { endpoint: "show" } });
  check(page, { "show 200": (r) => r.status === 200 });
  http.get(`${play}/manifest`, { tags: { endpoint: "manifest" } });
  http.get(`${BASE}/service-worker`, { tags: { endpoint: "service_worker" } });
  sleep(60 * DWELL);

  // 2. Consent.
  const consent = http.post(`${play}/consent`, JSON.stringify({ session_token: session, agreed: true }),
    { headers: JSON_HEADERS, tags: { endpoint: "consent" } });
  check(consent, { "consent ok": (r) => r.status === 200 });
  sleep(30 * DWELL);

  // 3. One mid-survey progress save (fires once per respondent — verified
  //    against player_controller.js's _registered guard).
  const partial = answers(i);
  const midway = { "1": partial["1"], "2": partial["2"] };
  const progress = http.post(`${play}/progress`, payload(session, midway, playerKey),
    { headers: JSON_HEADERS, tags: { endpoint: "progress" } });
  check(progress, { "progress ok": (r) => r.status === 200 });
  sleep(120 * DWELL);

  // 4. Submit the full deck.
  const submit = http.post(`${play}/submit`, payload(session, partial, playerKey),
    { headers: JSON_HEADERS, tags: { endpoint: "submit" } });
  check(submit, { "submit ok": (r) => r.status === 200 });
  sleep(5 * DWELL);

  // 5. The auto-fired leaderboard on the thank-you screen.
  const lb = http.get(`${play}/leaderboard?session_token=${session}&player_key=${encodeURIComponent(playerKey)}`,
    { tags: { endpoint: "leaderboard" } });
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
    http.post(`${play}/submit`, body, { headers: JSON_HEADERS, tags: { endpoint: "retry_echo" } });
  }
}
