import { NextRequest, NextResponse } from "next/server";
import { timingSafeEqual } from "node:crypto";

export const runtime = "nodejs";

function verifySecretToken(request: NextRequest): boolean {
  const expected = process.env.TELEGRAM_WEBHOOK_SECRET;
  if (!expected) return true; // not configured yet — see setup note in .env.example
  const received = request.headers.get("x-telegram-bot-api-secret-token");
  if (!received) return false;
  const expectedBuf = Buffer.from(expected);
  const receivedBuf = Buffer.from(received);
  return expectedBuf.length === receivedBuf.length && timingSafeEqual(expectedBuf, receivedBuf);
}

/**
 * Receives Telegram bot Update objects — registered via setWebhook with a
 * secret_token, checked against TELEGRAM_WEBHOOK_SECRET below (Telegram's
 * own recommended webhook-auth mechanism: https://core.telegram.org/bots/api#setwebhook).
 *
 * Currently a no-op past auth: this used to forward classic-deep-link
 * `/start <payload>` commands to the Taddy ad SDK's bot-side /events/start
 * call, which has been removed along with the rest of that integration.
 * The route (and the webhook registration itself, still live at Telegram's
 * side) is left in place as the wiring point for whatever inbound message
 * handling comes next — note that deep-link path was distinct from the
 * ?startapp= Mini App links used elsewhere (partner cross-app tasks,
 * referral codes), which never touch this webhook at all; those arrive
 * only via initData.start_param when the Mini App itself opens.
 *
 * Always acks Telegram with 200 — Telegram retries/backs off webhooks that
 * don't respond promptly, and eventually disables them.
 */
export async function POST(request: NextRequest) {
  if (!verifySecretToken(request)) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  return NextResponse.json({ ok: true });
}
