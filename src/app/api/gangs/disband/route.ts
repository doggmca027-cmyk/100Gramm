import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** The leader's only way out of their own gang — deletes it outright (ON DELETE CASCADE drops every member row too). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);

    const supabase = supabaseServer();
    const { error } = await supabase.rpc("disband_gang", { p_user_id: userId });
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
