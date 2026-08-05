import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const tiers = Array.isArray(body?.tiers) ? body.tiers.map(Number) : null;
    if (!tiers || tiers.length !== 4 || tiers.some((t: number) => !Number.isInteger(t))) {
      return NextResponse.json({ error: "invalid_combo_tiers" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("submit_daily_combo_guess", {
      p_user_id: userId,
      p_tiers: tiers,
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
