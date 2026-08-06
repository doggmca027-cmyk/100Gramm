import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { getGramUsdtRate } from "@/lib/gram-rate";
import { sweepUsdtDeposits } from "@/lib/usdt-deposit-sweep";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const supabase = supabaseServer();

    // Opportunistic, self-throttled background work riding along on normal
    // traffic — same pattern process_auto_collect_cycles already uses.
    // Neither blocks/fails the state fetch on its own hiccup:
    //  - rate refresh: keeps get_player_state's `exchange_rate` (a plain
    //    read — plpgsql can't make the outbound HTTP call itself) ≤60s
    //    stale (lib/gram-rate.ts).
    //  - deposit sweep: catches manual USDT transfers sent straight to the
    //    treasury address from outside TON Connect (lib/usdt-deposit-sweep.ts).
    await Promise.all([
      getGramUsdtRate(supabase).catch(() => null),
      sweepUsdtDeposits(supabase).catch(() => null),
    ]);

    const { data, error } = await supabase.rpc("get_player_state", { p_user_id: userId });
    if (error) throw error;
    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
