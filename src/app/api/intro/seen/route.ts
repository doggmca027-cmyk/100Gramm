import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const supabase = supabaseServer();
    const { error } = await supabase.rpc("mark_intro_seen", { p_user_id: userId });
    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
