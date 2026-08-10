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
  unknown_boost: 404,
  boost_not_pending: 409,
  tier_already_boosted: 409,
  amount_too_low: 400,
  unknown_pack: 404,
  invalid_tx_hash: 400,
  tx_already_used: 409,
  payment_not_found: 404,
  payment_mismatch: 400,
  withdrawal_already_pending: 409,
  request_not_found: 404,
  payout_address_missing: 400,
  invalid_address: 400,
  payout_failed: 502,
  unknown_item: 400,
  item_not_available: 409,
  cycle_not_found: 404,
  task_not_claimable: 409,
  not_verified: 409,
  too_early: 409,
  invalid_plan: 400,
  unknown_deposit: 404,
  deposit_not_active: 409,
  deposit_not_matured: 409,
  already_in_gang: 409,
  invalid_name_length: 400,
  invalid_name_chars: 400,
  name_taken: 409,
  gang_not_found: 404,
  gang_full: 409,
  not_in_gang: 409,
  leader_cannot_leave: 409,
  not_gang_leader: 409,
  invalid_role: 400,
  not_gang_member: 404,
  cannot_change_leader_role: 400,
  cannot_kick_leader: 400,
  cannot_kick_self: 400,
  insufficient_gang_bank: 409,
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
