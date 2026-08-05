import { NextRequest, NextResponse } from "next/server";
import { Address } from "@ton/core";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const amount = Number(body?.amount);
    const payoutAddress = typeof body?.payoutAddress === "string" ? body.payoutAddress.trim() : "";

    if (!Number.isFinite(amount) || amount <= 0) {
      return NextResponse.json({ error: "invalid_amount" }, { status: 400 });
    }

    if (!payoutAddress) {
      return NextResponse.json({ error: "payout_address_missing" }, { status: 400 });
    }
    try {
      Address.parse(payoutAddress);
    } catch {
      return NextResponse.json({ error: "invalid_address" }, { status: 400 });
    }

    const supabase = supabaseServer();
    // Doesn't pay out on its own — escrows the amount and files a pending
    // request an admin has to approve/reject; approval sends the actual TON
    // (see 0025_automatic_withdrawal_payout.sql + lib/ton-wallet-sender.ts).
    const { data: result, error } = await supabase.rpc("request_withdrawal", {
      p_user_id: userId,
      p_amount: amount,
      p_payout_address: payoutAddress,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ result, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
