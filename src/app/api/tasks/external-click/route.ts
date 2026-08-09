import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/**
 * Mints (or reuses) the one-time click token for an external_api partner
 * task — called when the player taps "Выполнить". The returned target_url
 * already has the token appended; the client just opens it. See
 * create_partner_task_click (0055_partner_cross_app_tasks.sql) for the
 * reuse-on-re-tap behavior.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const taskId = body?.taskId;
    if (typeof taskId !== "string" || !taskId) {
      return NextResponse.json({ error: "invalid_task" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data, error } = await supabase.rpc("create_partner_task_click", {
      p_user_id: userId,
      p_task_id: taskId,
    });
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
