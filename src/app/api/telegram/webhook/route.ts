import { NextRequest, NextResponse } from "next/server";
import { timingSafeEqual } from "node:crypto";
import { reportTaddyStart } from "@/lib/taddy";

export const runtime = "nodejs";

interface TelegramUpdate {
  message?: {
    text?: string;
    from?: {
      id: number;
      username?: string;
      first_name?: string;
      last_name?: string;
      language_code?: string;
      is_premium?: boolean;
    };
  };
}

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
 * Scope, deliberately narrow: this bot otherwise has no inbound message
 * handling anywhere in the app (see the getWebhookInfo check that led here
 * — no webhook was ever registered, so /start and every other message just
 * queued up unread at Telegram). The only thing wired up right now is
 * forwarding classic-deep-link `/start <payload>` commands to Taddy's
 * /events/start (lib/taddy.ts) — that's what their bot-side integration is
 * built around. Note this is a *different* deep-link path than the
 * ?startapp= Mini App links used elsewhere in this app (partner cross-app
 * tasks, referral codes) — those never touch this webhook at all; they
 * arrive only via initData.start_param when the Mini App itself opens.
 *
 * Always acks Telegram with 200 quickly regardless of what happened
 * downstream (Taddy being slow/down included) — Telegram retries/backs off
 * webhooks that don't respond promptly, and eventually disables them.
 */
export async function POST(request: NextRequest) {
  if (!verifySecretToken(request)) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const update = (await request.json().catch(() => null)) as TelegramUpdate | null;
  const text = update?.message?.text;
  const from = update?.message?.from;

  if (text && from && /^\/start(@\S+)?(\s|$)/.test(text)) {
    const payload = text.replace(/^\/start(@\S+)?\s*/, "").trim();
    await reportTaddyStart(
      {
        id: from.id,
        username: from.username,
        first_name: from.first_name,
        last_name: from.last_name,
        language_code: from.language_code,
        is_premium: from.is_premium,
      },
      payload || undefined,
    );
  }

  return NextResponse.json({ ok: true });
}
