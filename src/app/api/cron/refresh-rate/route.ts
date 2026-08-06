import { NextRequest, NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase-server";
import { getGramUsdtRate } from "@/lib/gram-rate";
import { sweepUsdtDeposits } from "@/lib/usdt-deposit-sweep";
import { sweepTonDeposits } from "@/lib/ton-deposit-sweep";

export const runtime = "nodejs";

/**
 * Backstop for the background work that's otherwise opportunistic
 * (piggybacked on /api/state's own traffic, see that route and
 * lib/gram-rate.ts / lib/ton-deposit-sweep.ts / lib/usdt-deposit-sweep.ts) —
 * same role /api/cron/auto-collect plays for auto-collect. This just
 * covers a stretch where nobody's using the app at all: the rate cache
 * would otherwise go stale indefinitely, and a manual TON/USDT deposit
 * pasted into some external wallet would sit uncredited until someone
 * next opens the app.
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
    const [rate] = await Promise.all([
      getGramUsdtRate(supabase),
      sweepTonDeposits(supabase),
      sweepUsdtDeposits(supabase),
    ]);
    return NextResponse.json({ ok: true, ...rate });
  } catch (error) {
    console.error("refresh-rate cron failed:", error);
    return NextResponse.json({ error: "internal_error" }, { status: 500 });
  }
}
