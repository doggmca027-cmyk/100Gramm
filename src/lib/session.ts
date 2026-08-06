import "server-only";
import type { NextRequest } from "next/server";
import { SESSION_COOKIE_NAME, verifySessionToken } from "./telegram-auth";
import { isAdminTelegramId } from "./admin";
import { supabaseServer } from "./supabase-server";

export class UnauthorizedError extends Error {
  constructor() {
    super("unauthorized");
  }
}

/**
 * CSRF guard for the session cookie. The cookie is issued with
 * `sameSite: "none"` (required — the Mini App runs inside Telegram's own
 * WebView/iframe, which browsers treat as cross-site relative to this
 * app's own domain), so browsers *will* attach it to a request from any
 * origin, not just this app. Without this check, a page on some unrelated
 * site could POST to a mutating endpoint and ride the ambient cookie.
 *
 * Deliberately conservative: only rejects when the browser sent an
 * `Origin` header that explicitly names a *different, real* origin. A
 * same-site fetch from this app's own frontend always matches; a missing
 * Origin, or the literal string "null" (which sandboxed iframes/WebViews
 * send when their sandbox lacks `allow-same-origin` — plausible for some
 * Telegram client/platform combination we have no way to test against
 * here), is let through rather than risk false-positive lockouts. This
 * still blocks the actual common case — an ordinary, unsandboxed page on
 * a different domain — since that always sends its own real origin.
 * GET/HEAD are exempt — they don't mutate anything, so there's nothing
 * for CSRF to abuse.
 */
function assertTrustedOrigin(request: NextRequest): void {
  if (request.method === "GET" || request.method === "HEAD") return;

  const appOrigin = process.env.NEXT_PUBLIC_APP_URL;
  if (!appOrigin) return;

  const origin = request.headers.get("origin");
  if (origin && origin !== "null" && origin !== appOrigin) {
    throw new UnauthorizedError();
  }
}

/** Reads and verifies the session cookie, returning the Supabase user id. */
export async function requireUserId(request: NextRequest): Promise<string> {
  assertTrustedOrigin(request);

  const token = request.cookies.get(SESSION_COOKIE_NAME)?.value;
  if (!token) {
    throw new UnauthorizedError();
  }

  const userId = await verifySessionToken(token);
  if (!userId) {
    throw new UnauthorizedError();
  }

  return userId;
}

/**
 * Same as requireUserId, but also checks the caller's own telegram_id
 * (looked up server-side, never trusting anything the client sends)
 * against the admin allowlist.
 */
export async function requireAdminUserId(request: NextRequest): Promise<string> {
  const userId = await requireUserId(request);

  const supabase = supabaseServer();
  const { data } = await supabase.from("users").select("telegram_id").eq("id", userId).single();
  if (!data || !isAdminTelegramId(String(data.telegram_id))) {
    throw new UnauthorizedError();
  }

  return userId;
}

/**
 * Resolves a Supabase user id to its Telegram id — used as the TON transfer
 * comment for deposits (see /api/wallet/ton-deposit/*) so it's human-
 * readable for manual reconciliation, same identity already shown to admins
 * on withdrawal requests. Never trust a telegram_id the client claims; this
 * always re-derives it server-side from the session-verified user id.
 */
export async function getTelegramId(userId: string): Promise<string> {
  const supabase = supabaseServer();
  const { data, error } = await supabase.from("users").select("telegram_id").eq("id", userId).single();
  if (error) throw error;
  return String(data.telegram_id);
}
