import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { getGramUsdtRate } from "@/lib/gram-rate";

export const runtime = "nodejs";

/**
 * Standalone rate readout for callers that just want the number (a
 * live-updating price badge) without pulling the whole player state.
 * /api/state also carries the same value (see get_player_state's
 * `exchange_rate` field) refreshed the same way — this is the lighter path.
 */
export async function GET(request: NextRequest) {
  try {
    await requireUserId(request);
    const supabase = supabaseServer();
    const rate = await getGramUsdtRate(supabase);
    return NextResponse.json(rate);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
