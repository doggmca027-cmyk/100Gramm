import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const tier = Number(body?.tier);
    if (!Number.isInteger(tier) || tier <= 0) {
      return NextResponse.json({ error: "invalid_tier" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data: cycleId, error } = await supabase.rpc("buy_max_slots", {
      p_user_id: userId,
      p_tier: tier,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ cycleId, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
