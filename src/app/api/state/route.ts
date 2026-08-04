import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const supabase = supabaseServer();
    const { data, error } = await supabase.rpc("get_player_state", { p_user_id: userId });
    if (error) throw error;
    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
