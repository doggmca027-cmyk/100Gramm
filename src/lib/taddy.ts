import "server-only";

/**
 * Taddy (https://taddy.gitbook.io/docs) — the ad/traffic-exchange platform
 * whose web SDK is already loaded site-wide (see app/layout.tsx). This is
 * the *bot-side* half: their REST API, called directly since there's no
 * official Node.js SDK yet (only PHP is released; Node/Go/Python are
 * listed "soon" in their docs as of this writing) — the API itself is
 * plain HTTP, so no SDK is actually required.
 *
 * Base URL and the /events/start shape come from Taddy's own OpenAPI spec
 * (https://api.taddy.pro/openapi/v1.yaml). A mirror exists at
 * https://t.tadly.pro/v1 per their docs, not wired in here — add a fallback
 * if the primary host turns out to be unreliable in practice.
 */
const TADDY_API_BASE = "https://api.taddy.pro/v1";

export interface TaddyUser {
  id: number;
  username?: string;
  first_name?: string;
  last_name?: string;
  language_code?: string;
  is_premium?: boolean;
}

function taddyPubId(): string | null {
  const pubId = process.env.TADDY_PUB_ID;
  if (!pubId) {
    console.error("TADDY_PUB_ID is not configured — skipping Taddy call");
    return null;
  }
  return pubId;
}

/**
 * Reports a `/start` (optionally `/start <payload>`) to Taddy — this is
 * what actually "registers" the bot side of the integration per their
 * docs; nothing to configure on their end beyond having a valid pubId.
 * Never throws — the Telegram webhook that calls this must always ack
 * Telegram quickly regardless of whether Taddy's own API is up, same
 * "never let a third-party call break our own critical path" stance as
 * notifyPartnerCallback (lib/partner-webhook.ts).
 */
export async function reportTaddyStart(user: TaddyUser, payload?: string): Promise<void> {
  const pubId = taddyPubId();
  if (!pubId) return;

  try {
    const res = await fetch(`${TADDY_API_BASE}/events/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pubId, user, payload: payload || undefined }),
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) {
      console.error(`Taddy /events/start failed: ${res.status} ${await res.text().catch(() => "")}`);
    }
  } catch (err) {
    console.error("Taddy /events/start request failed:", err);
  }
}
