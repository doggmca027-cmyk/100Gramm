import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-only promote/demote between 'member' and 'co_leader' — see set_gang_member_role (0061_gang_donate_roles_kick.sql). */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ userId: string }> },
) {
  try {
    const callerId = await requireUserId(request);
    const { userId: targetUserId } = await params;
    const body = await request.json().catch(() => null);
    const role = typeof body?.role === "string" ? body.role : "";

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("set_gang_member_role", {
      p_user_id: callerId,
      p_target_user_id: targetUserId,
      p_role: role,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: callerId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ result, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
