import { NextRequest, NextResponse } from "next/server";
import { requireUserId, getTelegramId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { getGramUsdtRate } from "@/lib/gram-rate";
import { resolveJettonWalletAddress } from "@/lib/ton-verify";
import { USDT_JETTON_MASTER, usdtToUnits, JETTON_FORWARD_TON_NANO } from "@/lib/usdt-jetton";
import { MIN_DEPOSIT_GRAM } from "@/lib/deposit-config";

export const runtime = "nodejs";

const VALID_SECONDS = 10 * 60;

/**
 * Quotes a direct USDT (Jetton) payment — either a fixed amount for a
 * specific tier's cycle price (p_tier) or an arbitrary top-up amount
 * (p_gramAmount), covering both "прямая оплата циклов" and "пополнение через
 * USDT" from the spec with one endpoint: whichever amount comes out of this
 * quote gets credited to GRAM balance once verify/route.ts confirms the
 * on-chain transfer — the caller (client) decides afterwards whether to
 * leave it as a balance top-up or immediately spend it via /api/cycles/start,
 * exactly mirroring how a TON deposit already works.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const buyerAddress = typeof body?.buyerAddress === "string" ? body.buyerAddress : null;
    if (!buyerAddress) {
      return NextResponse.json({ error: "wallet_not_connected" }, { status: 400 });
    }

    const supabase = supabaseServer();
    let gramAmount: number;

    const tier = Number(body?.tier);
    if (Number.isInteger(tier) && tier > 0) {
      const { data: seasonId, error: seasonError } = await supabase.rpc("active_season_id");
      if (seasonError) throw seasonError;
      if (!seasonId) return NextResponse.json({ error: "no_active_season" }, { status: 409 });

      const { data: product, error: productError } = await supabase
        .from("product_templates")
        .select("price")
        .eq("season_id", seasonId)
        .eq("tier", tier)
        .maybeSingle();
      if (productError) throw productError;
      if (!product) return NextResponse.json({ error: "unknown_tier" }, { status: 404 });
      gramAmount = Number(product.price);
    } else {
      gramAmount = Number(body?.gramAmount);
      if (!Number.isFinite(gramAmount) || gramAmount < MIN_DEPOSIT_GRAM) {
        return NextResponse.json({ error: "amount_too_low", min: MIN_DEPOSIT_GRAM }, { status: 400 });
      }
    }

    const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
    if (!treasuryAddress) {
      console.error("NEXT_PUBLIC_GAME_TREASURY_WALLET is not configured");
      return NextResponse.json({ error: "shop_not_configured" }, { status: 500 });
    }

    const rate = await getGramUsdtRate(supabase);
    const usdtAmount = gramAmount * rate.rate;
    const usdtAmountUnits = usdtToUnits(usdtAmount);

    const buyerJettonWallet = await resolveJettonWalletAddress(USDT_JETTON_MASTER, buyerAddress);
    if (!buyerJettonWallet) {
      return NextResponse.json({ error: "jetton_wallet_not_found" }, { status: 409 });
    }

    const telegramId = await getTelegramId(userId);

    // Locks gram_amount/usdt_amount/rate in *now* — verify/route.ts reads
    // this back by id instead of trusting a client-resubmitted amount, so
    // neither a slow wallet approval (rate drifting under it) nor a
    // tampered request can change what actually gets credited. See
    // 0032_usdt_manual_deposits.sql's header for the bug this replaced.
    const { data: quoteId, error: quoteError } = await supabase.rpc("create_usdt_payment_quote", {
      p_user_id: userId,
      p_comment: telegramId,
      p_gram_amount: gramAmount,
      p_usdt_amount: usdtAmount,
      p_rate: rate.rate,
      p_ttl_seconds: VALID_SECONDS,
    });
    if (quoteError) throw quoteError;

    return NextResponse.json({
      quoteId,
      // `to:` for the TonConnect message — the buyer's OWN Jetton wallet contract.
      jettonWalletAddress: buyerJettonWallet,
      // `destination:` inside the transfer body — where the jettons end up (the treasury owner).
      destinationAddress: treasuryAddress,
      // `response_destination:` inside the transfer body — where leftover TON is refunded.
      responseDestination: buyerAddress,
      usdtAmountUnits: usdtAmountUnits.toString(),
      forwardTonAmountNano: JETTON_FORWARD_TON_NANO.toString(),
      comment: telegramId,
      gramAmount,
      usdtAmount,
      rate: rate.rate,
      validUntil: Math.floor(Date.now() / 1000) + VALID_SECONDS,
    });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
