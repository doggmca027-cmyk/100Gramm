import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { loadAdminDailyCombo } from "@/lib/daily-combo";
import { notifyAmbassadorsOfDailyCombo } from "@/lib/notify-ambassadors-combo";

export const runtime = "nodejs";
export const maxDuration = 60;

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

    const result = await loadAdminDailyCombo(seasonId);

    // Reshuffling changes today's correct answer — re-notify so no
    // ambassador is left holding a now-wrong one. Best-effort: a Telegram
    // hiccup here shouldn't fail the regenerate action itself.
    try {
      await notifyAmbassadorsOfDailyCombo();
    } catch (notifyError) {
      console.error("Failed to notify ambassadors after combo regenerate:", notifyError);
    }

    return NextResponse.json(result);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
