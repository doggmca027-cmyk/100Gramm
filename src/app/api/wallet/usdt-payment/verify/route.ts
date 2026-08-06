import { NextRequest, NextResponse } from "next/server";
import { requireUserId, getTelegramId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { pollForTreasuryJettonPayment } from "@/lib/ton-verify";
import { USDT_JETTON_MASTER, usdtToUnits } from "@/lib/usdt-jetton";

export const runtime = "nodejs";

/** Per spec 3.2 — accept a small amount of adverse rounding between the quote and the on-chain send. */
const SLIPPAGE_TOLERANCE = 0.01;

/**
 * Verifies a USDT (Jetton) payment already broadcast by the wallet against
 * the *locked* quote created in prepare/route.ts (see
 * 0032_usdt_manual_deposits.sql) — quoteId is the only thing trusted from
 * the client; gram_amount/usdt_amount/comment all come from the quote row,
 * never re-derived from a live rate or a client-resubmitted number. Once
 * matched, credits exactly the quoted gram_amount (a fixed-price purchase,
 * not a rate-recomputed one) and marks the quote consumed.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const quoteId = typeof body?.quoteId === "string" ? body.quoteId : null;
    if (!quoteId) {
      return NextResponse.json({ error: "invalid_quote" }, { status: 400 });
    }

    const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
    if (!treasuryAddress) {
      console.error("NEXT_PUBLIC_GAME_TREASURY_WALLET is not configured");
      return NextResponse.json({ error: "shop_not_configured" }, { status: 500 });
    }

    const supabase = supabaseServer();
    const { data: quote, error: quoteError } = await supabase
      .from("usdt_payment_quotes")
      .select("gram_amount, usdt_amount, comment, expires_at, consumed_at")
      .eq("id", quoteId)
      .eq("user_id", userId)
      .maybeSingle();
    if (quoteError) throw quoteError;
    if (!quote) {
      return NextResponse.json({ error: "invalid_quote" }, { status: 404 });
    }
    if (quote.consumed_at) {
      return NextResponse.json({ error: "tx_already_used" }, { status: 409 });
    }
    if (new Date(quote.expires_at).getTime() < Date.now()) {
      return NextResponse.json({ error: "quote_expired" }, { status: 409 });
    }

    // Telegram id is re-derived from the session (never trusted from the
    // quote row's own comment column beyond "this is what we're matching
    // on") purely as a defense-in-depth cross-check — quote.comment was
    // itself server-computed at prepare time, so in practice these always
    // agree, but there's no reason to skip the belt-and-suspenders check.
    const telegramId = await getTelegramId(userId);
    if (quote.comment !== telegramId) {
      return NextResponse.json({ error: "invalid_quote" }, { status: 409 });
    }

    const expectedUnits = usdtToUnits(Number(quote.usdt_amount) * (1 - SLIPPAGE_TOLERANCE));
    const payment = await pollForTreasuryJettonPayment(
      treasuryAddress,
      USDT_JETTON_MASTER,
      expectedUnits,
      telegramId,
    );
    if (!payment) {
      return NextResponse.json({ error: "payment_not_found" }, { status: 404 });
    }

    // Credits the *quoted* gram_amount, not payment.valueNano converted back
    // — this is a fixed-price purchase (tier price or an explicit top-up
    // amount), same as buying anything else at a set price. Overpaying
    // doesn't buy extra GRAM; underpaying beyond SLIPPAGE_TOLERANCE simply
    // never matches above. Passive/unprompted transfers (paste-in manual
    // deposits with no prior quote) go through a different path — see
    // lib/usdt-deposit-sweep.ts — which *does* credit the real received
    // amount, because there's no fixed price to hold it to.
    const { data: result, error: creditError } = await supabase.rpc("credit_usdt_payment", {
      p_user_id: userId,
      p_tx_hash: payment.txHash,
      p_usdt_amount: Number(quote.usdt_amount),
      p_gram_amount: Number(quote.gram_amount),
      p_quote_id: quoteId,
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
