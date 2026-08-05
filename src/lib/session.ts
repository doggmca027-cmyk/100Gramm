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

/** Reads and verifies the session cookie, returning the Supabase user id. */
export async function requireUserId(request: NextRequest): Promise<string> {
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
