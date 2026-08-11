import { NextRequest, NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase-server";

export const runtime = "nodejs";

/**
 * Backstop for the weekly Syndicate leaderboard's own lazy catch-up —
 * get_player_state already calls finalize_weekly_leaderboard_season()
 * unconditionally on every request (see
 * 0070_syndicate_weekly_leaderboard.sql's header), so correctness never
 * depends on this cron firing. This just makes the reset + 200 TON payout
 * happen right at Sunday 23:59 UTC instead of waiting for the next active
 * player to open the app, same role /api/cron/finalize-district-battles
 * plays for District Wars. Scheduled "59 23 * * 0" in vercel.json.
 *
 * Vercel invokes scheduled functions with `Authorization: Bearer $CRON_SECRET`
 * automatically once that env var is set — see vercel.json for the schedule.
 */
export async function GET(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (secret) {
    const auth = request.headers.get("authorization");
    if (auth !== `Bearer ${secret}`) {
      return NextResponse.json({ error: "unauthorized" }, { status: 401 });
    }
  }

  try {
    const supabase = supabaseServer();
    const { error } = await supabase.rpc("finalize_weekly_leaderboard_season");
    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error("finalize-weekly-leaderboard cron failed:", error);
    return NextResponse.json({ error: "internal_error" }, { status: 500 });
  }
}
