import { NextRequest, NextResponse } from "next/server";
import { notifyAmbassadorsOfDailyCombo } from "@/lib/notify-ambassadors-combo";

export const runtime = "nodejs";
export const maxDuration = 60;

/**
 * Daily backstop that DMs every ambassador today's daily-combo secret
 * answer (see lib/notify-ambassadors-combo.ts). Scheduled a few minutes
 * after UTC midnight — by then today's combo row normally already exists
 * (either from the optional pg_cron ensure_daily_combo job in
 * 0014_daily_combo.sql, or simply from the first player/admin request of
 * the new day), but notifyAmbassadorsOfDailyCombo() also calls
 * ensure_daily_combo itself via loadAdminDailyCombo, so this route is
 * self-sufficient either way — it never depends on pg_cron being enabled
 * on the Supabase project.
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
    const result = await notifyAmbassadorsOfDailyCombo();
    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    console.error("notify-ambassadors-combo cron failed:", error);
    return NextResponse.json({ error: "internal_error" }, { status: 500 });
  }
}
