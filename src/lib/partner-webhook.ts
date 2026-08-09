import "server-only";
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

/** Fresh shared secret for a partner_apps row — used both at registration and on rotation. */
export function generatePartnerSecret(): string {
  return randomBytes(24).toString("hex");
}

/**
 * Shared wire format for both directions of the cross-app task postback
 * (see supabase/migrations/0055_partner_cross_app_tasks.sql's header for
 * the full picture): POST {token, success}, signed with a per-partner
 * shared secret as hex(HMAC-SHA256(secret, raw_body)) in the
 * X-100GRAM-Signature header. Same convention we use to verify Telegram's
 * own initData (see lib/telegram-auth.ts) — HMAC over the raw bytes,
 * constant-time compare, length-checked first since timingSafeEqual throws
 * (rather than returning false) on a length mismatch and the received
 * signature is attacker-controlled.
 */
export const SIGNATURE_HEADER = "x-100gram-signature";

export function signPayload(secret: string, rawBody: string): string {
  return createHmac("sha256", secret).update(rawBody).digest("hex");
}

export function verifySignature(secret: string, rawBody: string, receivedSignature: string | null): boolean {
  if (!receivedSignature) return false;
  const expected = signPayload(secret, rawBody);
  const expectedBuf = Buffer.from(expected, "hex");
  const receivedBuf = Buffer.from(receivedSignature, "hex");
  return expectedBuf.length === receivedBuf.length && timingSafeEqual(expectedBuf, receivedBuf);
}

/**
 * Fire-and-verify POST to a partner's outgoing_callback_url, reporting
 * {token, success:true} for a user who opened our app via their link (see
 * api/auth/telegram/route.ts). Time-boxed and exception-swallowing on
 * purpose — this must never be able to slow down or break a user's login
 * just because some partner's endpoint is slow or down.
 */
export async function notifyPartnerCallback(
  url: string,
  secret: string,
  payload: { token: string; success: boolean },
): Promise<void> {
  const rawBody = JSON.stringify(payload);
  try {
    await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        [SIGNATURE_HEADER]: signPayload(secret, rawBody),
      },
      body: rawBody,
      signal: AbortSignal.timeout(4000),
    });
  } catch (err) {
    console.error("notifyPartnerCallback failed:", err);
  }
}

/** Prefix + separator for the ?startapp= payload a partner embeds their tracking token in. */
const INBOUND_PREFIX = "p100_";

/** Builds the value a partner should put after `?startapp=` to send us their user. */
export function buildInboundStartParam(partnerSlug: string, partnerToken: string): string {
  return `${INBOUND_PREFIX}${partnerSlug}_${partnerToken}`;
}

/**
 * Parses a Telegram start_param that might be one of ours. partnerSlug is
 * restricted to [a-z0-9-]+ at creation time (see partner_apps' check
 * constraint), so splitting on the *second* underscore is unambiguous even
 * though the partner-supplied token half can contain underscores itself.
 */
export function parseInboundStartParam(startParam: string): { partnerSlug: string; partnerToken: string } | null {
  if (!startParam.startsWith(INBOUND_PREFIX)) return null;
  const rest = startParam.slice(INBOUND_PREFIX.length);
  const separatorIndex = rest.indexOf("_");
  if (separatorIndex <= 0 || separatorIndex === rest.length - 1) return null;
  return {
    partnerSlug: rest.slice(0, separatorIndex),
    partnerToken: rest.slice(separatorIndex + 1),
  };
}
