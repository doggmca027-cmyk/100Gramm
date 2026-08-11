import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Explicit-confirm join for an OPEN gang with entry_price_gram > 0 — actually charges, unlike join_gang. See pay_and_join_gang (0078_gang_closed_paid_description.sql). */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const userId = await requireUserId(request);
    const { id } = await params;

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("pay_and_join_gang", {
      p_user_id: userId,
      p_gang_id: id,
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
