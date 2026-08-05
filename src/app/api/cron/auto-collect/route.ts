import { NextRequest, NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase-server";

export const runtime = "nodejs";

/**
 * Backstop for process_auto_collect_cycles() — the primary mechanism is
 * get_player_state() opportunistically running the same sweep on every
 * active user's request (see 0027_combo_item_drops.sql), since Vercel's
 * free-tier cron granularity (daily) is far coarser than cycle durations
 * and would leave auto-collect players waiting up to 24h if this were the
 * only trigger. This just covers the edge case of nobody using the app at
 * all for a stretch.
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
    const { data, error } = await supabase.rpc("process_auto_collect_cycles");
    if (error) throw error;

    return NextResponse.json({ ok: true, ...data });
  } catch (error) {
    console.error("auto-collect cron failed:", error);
    return NextResponse.json({ error: "internal_error" }, { status: 500 });
  }
}
