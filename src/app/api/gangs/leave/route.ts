import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leaders can't use this — leave_gang rejects with 'leader_cannot_leave'; they disband instead (see /api/gangs/disband). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);

    const supabase = supabaseServer();
    const { error } = await supabase.rpc("leave_gang", { p_user_id: userId });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
