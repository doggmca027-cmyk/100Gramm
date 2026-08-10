import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Public read — the "Кастомизация" shop catalog (avatars/frames, prices, glow hints). */
export async function GET(request: NextRequest) {
  try {
    await requireUserId(request);
    const supabase = supabaseServer();
    const { data, error } = await supabase.rpc("get_gang_cosmetics_catalog");
    if (error) throw error;
    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
