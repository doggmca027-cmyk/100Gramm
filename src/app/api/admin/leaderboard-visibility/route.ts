import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/**
 * Toggles the *caller's own* leaderboard visibility — always the
 * session-verified admin's own user id, never a target from the request
 * body, since this is "let me hide my own profile", not a moderation tool
 * for hiding other players.
 */
export async function PATCH(request: NextRequest) {
  try {
    const adminUserId = await requireAdminUserId(request);
    const body = await request.json().catch(() => null);
    const hidden = Boolean(body?.hidden);

    const supabase = supabaseServer();
    const { error } = await supabase.rpc("set_leaderboard_visibility", {
      p_user_id: adminUserId,
      p_hidden: hidden,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: adminUserId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
