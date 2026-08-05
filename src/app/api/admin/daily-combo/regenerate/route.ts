import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { loadAdminDailyCombo } from "@/lib/daily-combo";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const supabase = supabaseServer();

    const { data: seasonId, error: seasonError } = await supabase.rpc("active_season_id");
    if (seasonError) throw seasonError;
    if (!seasonId) {
      return NextResponse.json({ error: "no_active_season" }, { status: 409 });
    }

    const { error } = await supabase.rpc("regenerate_daily_combo", { p_season_id: seasonId });
    if (error) throw error;

    return NextResponse.json(await loadAdminDailyCombo(seasonId));
  } catch (error) {
    return apiErrorResponse(error);
  }
}
