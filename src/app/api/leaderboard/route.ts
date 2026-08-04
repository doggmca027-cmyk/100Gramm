import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    await requireUserId(request);

    const metric = request.nextUrl.searchParams.get("metric") ?? "total_earned";
    const limit = Number(request.nextUrl.searchParams.get("limit") ?? "50");

    const supabase = supabaseServer();
    const { data, error } = await supabase.rpc("get_leaderboard", {
      p_metric: metric === "completed_cycles_total" ? "completed_cycles_total" : "total_earned",
      p_limit: Number.isInteger(limit) && limit > 0 ? Math.min(limit, 100) : 50,
    });
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
