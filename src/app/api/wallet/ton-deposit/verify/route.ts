import { NextRequest, NextResponse } from "next/server";
import { fromNano, toNano } from "@ton/core";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { pollForTreasuryPayment } from "@/lib/ton-verify";

export const runtime = "nodejs";

/**
 * Verifies a TON Connect payment and, once confirmed, credits the balance
 * 1:1 with the actual on-chain amount received (never the client-claimed
 * `amountTon` — that's only used as the poll's matching floor). Verification
 * is independently re-derived from the treasury's own on-chain history, see
 * lib/ton-verify.ts for why that's more robust than resolving the `boc`
 * TonConnect's sendTransaction() returns to a transaction hash.
 *
 * Returns 404 payment_not_found while the transfer hasn't confirmed/indexed
 * yet — the client is expected to retry a few times with a short delay
 * rather than treat that as a hard failure.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const amountTon = Number(body?.amountTon);

    if (!Number.isFinite(amountTon) || amountTon <= 0) {
      return NextResponse.json({ error: "amount_too_low" }, { status: 400 });
    }

    const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
    if (!treasuryAddress) {
      console.error("NEXT_PUBLIC_GAME_TREASURY_WALLET is not configured");
      return NextResponse.json({ error: "shop_not_configured" }, { status: 500 });
    }

    const expectedNano = toNano(String(amountTon));
    // Must exactly match the comment the client was told to attach when it
    // built the transfer (see WalletConnectModal.tsx) — binds this specific
    // on-chain payment to this user.
    const payment = await pollForTreasuryPayment(treasuryAddress, expectedNano, userId);
    if (!payment) {
      return NextResponse.json({ error: "payment_not_found" }, { status: 404 });
    }

    const supabase = supabaseServer();
    const { data: result, error: creditError } = await supabase.rpc("credit_ton_deposit", {
      p_user_id: userId,
      p_tx_hash: payment.txHash,
      p_amount_ton: Number(fromNano(payment.valueNano)),
    });
    if (creditError) throw creditError;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ result, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
