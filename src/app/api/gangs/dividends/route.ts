import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-only: splits an amount from the gang bank evenly across every current member — see distribute_bank_dividends (0063_district_wars.sql). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const amount = typeof body?.amount === "number" ? body.amount : Number(body?.amount);

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("distribute_bank_dividends", {
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
