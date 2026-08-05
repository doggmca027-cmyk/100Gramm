import { NextRequest, NextResponse } from "next/server";
import { fromNano, toNano } from "@ton/core";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { pollForTreasuryPayment } from "@/lib/ton-verify";

export const runtime = "nodejs";

/**
 * Verifies a TON Connect payment and, once confirmed, credits the pack's
 * GRAM amount. Never trusts the client for price or amount — both come
 * from `gram_packs` — and never trusts it for "did this actually happen"
 * either, that's independently re-derived from the treasury's own on-chain
 * history (see lib/ton-verify.ts).
 *
 * `boc` (and `txHash`, if the caller happens to have it) are accepted per
 * the TON Connect flow's shape, but are informational only: verification
 * matches on-chain by (treasury address, amount, comment) rather than by
 * resolving these to a specific transaction — see ton-verify.ts for why.
 *
 * Returns 404 payment_not_found while the transfer hasn't confirmed/indexed
 * yet — the client is expected to retry a few times with a short delay
 * rather than treat that as a hard failure.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const packId = typeof body?.packId === "string" ? body.packId : null;

    if (!packId) {
      return NextResponse.json({ error: "invalid_pack_id" }, { status: 400 });
    }

    const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
    if (!treasuryAddress) {
      console.error("NEXT_PUBLIC_GAME_TREASURY_WALLET is not configured");
      return NextResponse.json({ error: "shop_not_configured" }, { status: 500 });
    }

    const supabase = supabaseServer();

    const { data: pack, error: packError } = await supabase
      .from("gram_packs")
      .select("id, price_ton")
      .eq("id", packId)
      .eq("is_active", true)
      .maybeSingle();
    if (packError) throw packError;
    if (!pack) {
      return NextResponse.json({ error: "unknown_pack" }, { status: 404 });
    }

    const expectedNano = toNano(String(pack.price_ton));
    // Must exactly match the comment the client was told to attach when it
    // built the transfer (see BuyItemModal.tsx) — binds this specific
    // on-chain payment to this user and this pack.
    const expectedComment = `${userId}:${packId}`;

    const payment = await pollForTreasuryPayment(treasuryAddress, expectedNano, expectedComment);
    if (!payment) {
      return NextResponse.json({ error: "payment_not_found" }, { status: 404 });
    }

    const amountTon = Number(fromNano(payment.valueNano));

    const { data: result, error: creditError } = await supabase.rpc("credit_gram_purchase", {
      p_user_id: userId,
      p_pack_id: packId,
      p_tx_hash: payment.txHash,
      p_amount_ton: amountTon,
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
