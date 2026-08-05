import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const VALID_STATUSES = new Set(["pending", "processing", "approved", "rejected"]);

export async function GET(request: NextRequest) {
  try {
    await requireAdminUserId(request);

    const statusParam = request.nextUrl.searchParams.get("status") ?? "pending";
    const status = VALID_STATUSES.has(statusParam) ? statusParam : "pending";

    const supabase = supabaseServer();
    const { data, error } = await supabase
      .from("withdrawal_requests")
      .select(
        "id, amount, fee, net_amount, status, created_at, resolved_at, admin_note, payout_address, payout_tx_hash, user:users(telegram_id, username, first_name)",
      )
      .eq("status", status)
      .order("created_at", { ascending: status === "pending" });
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
