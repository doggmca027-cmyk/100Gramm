import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-only approve/reject of a pending application — see respond_gang_join_request (0078_gang_closed_paid_description.sql). */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const userId = await requireUserId(request);
    const { id } = await params;
    const body = await request.json().catch(() => null);
    const approve = body?.approve === true;

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("respond_gang_join_request", {
      p_user_id: userId,
      p_request_id: id,
      p_approve: approve,
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
