import { NextResponse } from "next/server";
import { UnauthorizedError } from "./session";

/** RPC exceptions we raise on purpose (see supabase/migrations/0002_functions.sql) -> HTTP status. */
const KNOWN_RPC_ERRORS: Record<string, number> = {
  no_active_season: 409,
  tier_locked: 409,
  unknown_tier: 400,
  no_free_slots: 409,
  insufficient_balance: 409,
  container_not_ready: 409,
  quest_not_claimable: 409,
  unknown_task: 404,
  already_claimed: 409,
  invalid_combo_tiers: 400,
  slots_not_maxed: 409,
  already_completed: 409,
  no_attempts_left: 409,
};

/** Postgres wraps a plpgsql `raise exception 'x'` message as `x` (sometimes with a trailing detail). */
function matchKnownError(message: string): number | null {
  for (const code of Object.keys(KNOWN_RPC_ERRORS)) {
    if (message.includes(code)) return KNOWN_RPC_ERRORS[code];
  }
  return null;
}

export function apiErrorResponse(error: unknown): NextResponse {
  if (error instanceof UnauthorizedError) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  if (error && typeof error === "object" && "message" in error) {
    const message = String((error as { message: unknown }).message);
    const status = matchKnownError(message);
    if (status) {
      const code = Object.keys(KNOWN_RPC_ERRORS).find((c) => message.includes(c));
      return NextResponse.json({ error: code }, { status });
    }
  }

  console.error("Unhandled API error:", error);
  return NextResponse.json({ error: "internal_error" }, { status: 500 });
}
