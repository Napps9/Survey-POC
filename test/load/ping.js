// Path-only probe. Hammers ONE cheap endpoint — by default /up, Rails' health
// check: no database, no cache, no rate limit — at a constant arrival rate,
// from the same runners and through the same Cloudflare → Render proxy →
// Puma path as journey.js. Its purpose is to split the path from the app's
// work: runs 12–14 met the same ~185 req/s ceiling on three web-box shapes
// and with one or two generators, all of it http_req_waiting. If /up queues
// at the same rate, the ceiling is the path (edge, proxy, accept queue); if
// /up runs clean far above it, the ceiling is what the journeys touch — the
// database, the Key Value, or the app's own serialisation.
//
//   BASE_URL        scratch base URL (production hostnames are refused)
//   ARRIVALS_PER_S  here: REQUESTS per second (one request per iteration)
//   RAMP_S / HOLD_S ramp to the rate, hold it
//   PING_PATH       the path to hit (default /up)
import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.BASE_URL;
if (!BASE) throw new Error("BASE_URL is required");
if (/playverto\.com|survey-poc\.onrender\.com/.test(BASE) && __ENV.I_KNOW_THIS_IS_NOT_PROD !== "1") {
  throw new Error(`Refusing to load-test ${BASE}: that looks like production.`);
}
const RATE = Number(__ENV.ARRIVALS_PER_S || 100);
const RAMP_S = Number(__ENV.RAMP_S || 30);
const HOLD_S = Number(__ENV.HOLD_S || 90);
const PATH = __ENV.PING_PATH || "/up";

export const options = {
  scenarios: {
    ping: {
      executor: "ramping-arrival-rate",
      startRate: 0,
      timeUnit: "1s",
      // Enough VUs to keep the rate up even if every request queues for ~5 s.
      preAllocatedVUs: Math.max(50, RATE),
      maxVUs: Math.max(200, RATE * 5),
      stages: [
        { duration: `${RAMP_S}s`, target: RATE },
        { duration: `${HOLD_S}s`, target: RATE },
        { duration: "10s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<1000"],
  },
};

export default function () {
  const res = http.get(`${BASE}${PATH}`, { tags: { endpoint: "ping" } });
  check(res, { "ping 200": (r) => r.status === 200 });
}
