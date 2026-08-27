// Firebase App Check — proves the request came from OUR app, not a scraped-token script.
// Auth answers "who are you?"; App Check answers "what client is this?". Both are required.
//
// Mode is env-driven so you can follow Google's recommended rollout: monitor -> enforce.
//   APPCHECK_MODE=monitor  (default) verify + log, but allow through. Safe first deploy.
//   APPCHECK_MODE=enforce  reject any request without a valid App Check token (403).
//   APPCHECK_MODE=off      skip entirely (local emulator only).
import { getAppCheck } from "firebase-admin/app-check";

const MODE = (process.env.APPCHECK_MODE || "monitor").toLowerCase();

export const appCheckMode = MODE;

/**
 * @returns {Promise<{ok: boolean, reason: string}>}
 *   ok=false means the caller should reject with 403 (only ever happens in enforce mode).
 */
export async function verifyAppCheck(req) {
  if (MODE === "off") return { ok: true, reason: "disabled" };

  const token = req.headers["x-firebase-appcheck"];

  if (!token) {
    if (MODE === "enforce") return { ok: false, reason: "missing_appcheck_token" };
    console.warn("appcheck_monitor", { result: "missing_token" });
    return { ok: true, reason: "missing_token_monitored" };
  }

  try {
    await getAppCheck().verifyToken(String(token));
    return { ok: true, reason: "verified" };
  } catch (err) {
    if (MODE === "enforce") return { ok: false, reason: "invalid_appcheck_token" };
    console.warn("appcheck_monitor", { result: "invalid_token", code: err?.code || "unknown" });
    return { ok: true, reason: "invalid_token_monitored" };
  }
}
