import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-or-co_leader-only: buys a battle boost (airstrike_2x/3x or engineer_shield) — see activate_district_boost (0066_district_wars_monetization.sql). */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const userId = await requireUserId(request);
    const { id } = await params;
    const body = await request.json().catch(() => null);
    const boostType = typeof body?.boostType === "string" ? body.boostType : "";
    const payFromBank = Boolean(body?.payFromBank);

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("activate_district_boost", {
      p_user_id: userId,
      p_district_id: id,
      p_boost_type: boostType,
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
