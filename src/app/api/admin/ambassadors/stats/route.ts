import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const supabase = supabaseServer();
    const { data, error } = await supabase.rpc("get_ambassador_stats");
    if (error) throw error;
    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
