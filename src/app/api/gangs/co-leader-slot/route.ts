import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-only: buys +1 co_leader slot for 3 GRAM from their own balance — see purchase_co_leader_slot (0066_district_wars_monetization.sql). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("purchase_co_leader_slot", {
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
