import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-only removal of any non-leader member — see kick_gang_member (0061_gang_donate_roles_kick.sql). */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ userId: string }> },
) {
  try {
    const callerId = await requireUserId(request);
    const { userId: targetUserId } = await params;

    const supabase = supabaseServer();
    const { error } = await supabase.rpc("kick_gang_member", {
      p_user_id: callerId,
      p_target_user_id: targetUserId,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: callerId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
