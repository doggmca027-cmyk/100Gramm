import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Files an application to a CLOSED gang — no balance touched here, see request_join_gang (0078_gang_closed_paid_description.sql). */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const userId = await requireUserId(request);
    const { id } = await params;

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("request_join_gang", {
      p_user_id: userId,
      p_gang_id: id,
    });
    if (error) throw error;

    return NextResponse.json({ result });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
