import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-or-co_leader-only: hires the mercenary bot (auto +50/hour for the rest of today's window) — see activate_mercenary_bot (0066_district_wars_monetization.sql). */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const userId = await requireUserId(request);
    const { id } = await params;
    const body = await request.json().catch(() => null);
    const payFromBank = Boolean(body?.payFromBank);

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("activate_mercenary_bot", {
      p_user_id: userId,
      p_district_id: id,
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
