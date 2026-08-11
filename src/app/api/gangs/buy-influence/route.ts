import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-or-co_leader-only: instantly buys weekly Influence Points for the caller's gang — see buy_direct_influence (0070_syndicate_weekly_leaderboard.sql). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const tonAmount = Number(body?.tonAmount);
    const payFromBank = Boolean(body?.payFromBank);

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("buy_direct_influence", {
      p_user_id: userId,
      p_ton_amount: Number.isFinite(tonAmount) ? tonAmount : null,
      p_pay_from_bank: payFromBank,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ result, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
