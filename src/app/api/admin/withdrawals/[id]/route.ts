import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Approves or rejects a pending withdrawal request. */
export async function PATCH(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const adminUserId = await requireAdminUserId(request);
    const { id } = await params;
    const body = await request.json().catch(() => null);
    const approve = body?.approve === true;
    const note = typeof body?.note === "string" && body.note.trim() ? body.note.trim() : null;

    const supabase = supabaseServer();
    const { error } = await supabase.rpc("resolve_withdrawal_request", {
      p_request_id: id,
      p_admin_user_id: adminUserId,
      p_approve: approve,
      p_admin_note: note,
    });
    if (error) throw error;

    const { data, error: fetchError } = await supabase
      .from("withdrawal_requests")
      .select(
        "id, amount, fee, net_amount, status, created_at, resolved_at, admin_note, user:users(telegram_id, username, first_name)",
      )
      .eq("id", id)
      .single();
    if (fetchError) throw fetchError;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
