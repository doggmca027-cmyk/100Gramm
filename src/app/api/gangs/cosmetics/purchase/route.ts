import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-only: buys a premium avatar or frame for the gang — see purchase_gang_cosmetic (0066_district_wars_monetization.sql). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const cosmeticCode = typeof body?.cosmeticCode === "string" ? body.cosmeticCode : "";

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("purchase_gang_cosmetic", {
      p_user_id: userId,
      p_cosmetic_code: cosmeticCode,
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
