import { NextRequest, NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase-server";

export const runtime = "nodejs";

/**
 * Backstop for District Wars' own lazy catch-up — get_player_state
 * already calls resolve_due_district_battles() unconditionally on every
 * request (see 0065_district_wars_daily_battles.sql's header), so
 * correctness never depends on this cron firing. This just makes battles
 * resolve right at window-close instead of waiting for the next active
 * player to open the app, same role /api/cron/refresh-rate plays for the
 * rate cache. Scheduled for window_end_time (22:00 UTC) in vercel.json;
 * if a district's window_end_time is ever changed per-row, this cron's
 * schedule stops being "right at close" for that one district but
 * finalize still happens correctly on the next request regardless.
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
    const { error } = await supabase.rpc("resolve_due_district_battles");
    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error("finalize-district-battles cron failed:", error);
    return NextResponse.json({ error: "internal_error" }, { status: 500 });
  }
}
