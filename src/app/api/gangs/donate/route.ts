import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Any member tops up their own gang's bank from their own GRAM balance — see donate_to_gang_bank (0061_gang_donate_roles_kick.sql). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const amount = typeof body?.amount === "number" ? body.amount : Number(body?.amount);

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("donate_to_gang_bank", {
      p_user_id: userId,
      p_amount: amount,
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
