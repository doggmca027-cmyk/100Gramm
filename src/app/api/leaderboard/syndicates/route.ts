import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/**
 * The Leaderboard screen's "Синдикаты" tab — top-15 gangs by
 * weekly_influence_points, the weekly reset countdown, and the caller's
 * own gang's row (even when it isn't in the top 15). See
 * get_syndicate_leaderboard (0070_syndicate_weekly_leaderboard.sql).
 */
export async function GET(request: NextRequest) {
  try {
    const userId = await requireUserId(request);

    const supabase = supabaseServer();
    const { data, error } = await supabase.rpc("get_syndicate_leaderboard", {
      p_user_id: userId,
    });
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
