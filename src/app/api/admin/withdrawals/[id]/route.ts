import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { sendTonPayout } from "@/lib/ton-wallet-sender";

export const runtime = "nodejs";

/**
 * Approves or rejects a pending withdrawal request. Approval actually pays
 * out — three steps, each one only run if the previous one succeeded:
 *
 * 1. lock_withdrawal_for_payout() flips pending -> processing (the mutex —
 *    see 0025_automatic_withdrawal_payout.sql for why this has to happen
 *    before anything touches the treasury wallet).
 * 2. sendTonPayout() signs and broadcasts the real TON transfer.
 * 3. resolve_withdrawal_request() flips processing -> approved and records
 *    the payout's tx hash.
 *
 * If step 2 throws, step 3 never runs — revert_withdrawal_processing() puts
 * the request back to 'pending' so the admin sees the failure (e.g. treasury
 * out of funds) and can retry, instead of it being stuck in limbo.
 */
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

    if (approve) {
      const { data: locked, error: lockError } = await supabase.rpc("lock_withdrawal_for_payout", {
        p_request_id: id,
        p_admin_user_id: adminUserId,
      });
      if (lockError) throw lockError;

      let payoutTxHash: string | null = null;
      try {
        const payout = await sendTonPayout(locked.payout_address, locked.net_amount, id);
        payoutTxHash = payout.txHash;
      } catch (sendError) {
        console.error(`Payout send failed for withdrawal ${id}:`, sendError);
        await supabase.rpc("revert_withdrawal_processing", { p_request_id: id });
        const reason = sendError instanceof Error ? sendError.message : "unknown_error";
        return NextResponse.json({ error: "payout_failed", reason }, { status: 502 });
      }

      const { error: resolveError } = await supabase.rpc("resolve_withdrawal_request", {
        p_request_id: id,
        p_admin_user_id: adminUserId,
        p_approve: true,
        p_admin_note: note,
        p_payout_tx_hash: payoutTxHash,
      });
      if (resolveError) throw resolveError;
    } else {
      const { error } = await supabase.rpc("resolve_withdrawal_request", {
        p_request_id: id,
        p_admin_user_id: adminUserId,
        p_approve: false,
        p_admin_note: note,
      });
      if (error) throw error;
    }

    const { data, error: fetchError } = await supabase
      .from("withdrawal_requests")
      .select(
        "id, amount, fee, net_amount, status, created_at, resolved_at, admin_note, payout_address, payout_tx_hash, user:users(telegram_id, username, first_name)",
      )
      .eq("id", id)
      .single();
    if (fetchError) throw fetchError;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
