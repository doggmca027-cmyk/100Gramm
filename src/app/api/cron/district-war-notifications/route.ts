import { NextRequest, NextResponse } from "next/server";
import { runDistrictWarNotifications } from "@/lib/notify-district-war";

export const runtime = "nodejs";
export const maxDuration = 60;

/**
 * Twice-daily: 30 minutes before District Wars' battle window opens, and
 * 30 minutes before it closes, DMs every Syndicate member (opening
 * reminder) / every member of a gang currently in an active fight
 * (closing reminder) — see lib/notify-district-war.ts.
 *
 * Self-guarding, not just a lazy-catch-up backstop like this schema's
 * other cron routes: run_district_war_notifications() (0073_district_war_
 * notifications.sql) decides for itself whether a reminder is actually due
 * right now and claims a one-per-(type, day) slot before sending anything,
 * so hitting this route more than once (a Vercel retry, a stray manual
 * curl) is always safe — outside the ~10-minute window around each of the
 * two marks it's a pure no-op.
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
    const result = await runDistrictWarNotifications();
    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    console.error("district-war-notifications cron failed:", error);
    return NextResponse.json({ error: "internal_error" }, { status: 500 });
  }
}
