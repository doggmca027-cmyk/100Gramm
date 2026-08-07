import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { loadAdminDailyCombo } from "@/lib/daily-combo";
import { notifyAmbassadorsOfDailyCombo } from "@/lib/notify-ambassadors-combo";

export const runtime = "nodejs";
export const maxDuration = 60;

export async function GET(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const supabase = supabaseServer();

    const { data: seasonId, error: seasonError } = await supabase.rpc("active_season_id");
    if (seasonError) throw seasonError;
    if (!seasonId) {
      return NextResponse.json({ error: "no_active_season" }, { status: 409 });
    }

    return NextResponse.json(await loadAdminDailyCombo(seasonId));
  } catch (error) {
    return apiErrorResponse(error);
  }
}

export async function PATCH(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const body = await request.json().catch(() => null);

    const tiers = Array.isArray(body?.tiers) ? body.tiers.map(Number) : null;
    if (!tiers || tiers.length !== 4 || tiers.some((t: number) => !Number.isInteger(t))) {
      return NextResponse.json({ error: "invalid_combo_tiers" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data: seasonId, error: seasonError } = await supabase.rpc("active_season_id");
    if (seasonError) throw seasonError;
    if (!seasonId) {
      return NextResponse.json({ error: "no_active_season" }, { status: 409 });
    }

    const { error } = await supabase.rpc("set_daily_combo_tiers", {
      p_season_id: seasonId,
      p_tiers: tiers,
    });
    if (error) throw error;

    const result = await loadAdminDailyCombo(seasonId);

    // Manually picking tiers changes today's correct answer too — same
    // re-notify as regenerate, same best-effort (non-fatal) handling.
    try {
      await notifyAmbassadorsOfDailyCombo();
    } catch (notifyError) {
      console.error("Failed to notify ambassadors after combo tiers set:", notifyError);
    }

    return NextResponse.json(result);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
