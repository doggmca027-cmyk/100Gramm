import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-only: one-time 10 GRAM upgrade to 30% APY gang bank interest — see purchase_vip_treasury (0066_district_wars_monetization.sql). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("purchase_vip_treasury", {
      p_user_id: userId,
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
