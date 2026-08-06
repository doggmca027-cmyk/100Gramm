import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import { fetchRecentJettonTransfersToTreasury } from "./ton-verify";
import { USDT_JETTON_MASTER, unitsToUsdt } from "./usdt-jetton";
import { getGramUsdtRate } from "./gram-rate";

/**
 * Passive counterpart to the prompted usdt-payment prepare/verify flow —
 * catches USDT sent straight to the treasury address from *any* wallet or
 * exchange (manual copy-paste of address + memo, see the deposit modal's
 * USDT tab), not just a TON Connect-signed transfer this app initiated.
 * There's nothing to poll-for-a-specific-match here: this reads the
 * treasury's recent incoming transfers, and for each one not already in
 * wallet_transactions, resolves the sender by their memo (the payer's own
 * Telegram id) and credits it — same "trust only what's on-chain, convert
 * at the live rate" rule as everywhere else in this file's payment paths.
 *
 * Throttled to at most once per MIN_SWEEP_INTERVAL_SECONDS via
 * try_claim_usdt_sweep_slot (an atomic UPDATE...WHERE in Postgres — see
 * 0032_usdt_manual_deposits.sql) so a burst of concurrent /api/state calls
 * doesn't all hit TonAPI at once. Called opportunistically from
 * /api/state and as a backstop from /api/cron/refresh-rate, same pattern
 * getGramUsdtRate itself already uses.
 */

const MIN_SWEEP_INTERVAL_SECONDS = 30;
/** Ignore dust below this — mirrors the deposit floors used elsewhere (MIN_DEPOSIT_TON, prepare's MIN_GRAM_AMOUNT). */
const MIN_USDT_AMOUNT = 0.05;

export async function sweepUsdtDeposits(supabase: SupabaseClient): Promise<void> {
  const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
  if (!treasuryAddress) return;

  try {
    const { data: claimed, error: claimError } = await supabase.rpc("try_claim_usdt_sweep_slot", {
      p_min_interval_seconds: MIN_SWEEP_INTERVAL_SECONDS,
    });
    if (claimError || !claimed) return;

    const transfers = await fetchRecentJettonTransfersToTreasury(treasuryAddress, USDT_JETTON_MASTER);
    if (transfers.length === 0) return;

    const rate = await getGramUsdtRate(supabase);

    for (const transfer of transfers) {
      const usdtAmount = unitsToUsdt(transfer.units);
      if (usdtAmount < MIN_USDT_AMOUNT) continue;

      // The memo is expected to be a bare Telegram id (see
      // walletConnect.usdtDeposit.memoHint) — anything else can't be
      // matched to a user and is left for manual admin reconciliation
      // rather than guessed at.
      const telegramId = transfer.comment?.trim();
      if (!telegramId || !/^\d+$/.test(telegramId)) continue;

      const { data: user } = await supabase
        .from("users")
        .select("id")
        .eq("telegram_id", telegramId)
        .maybeSingle();
      if (!user) continue;

      const creditedGram = Math.round((usdtAmount / rate.rate) * 100) / 100;
      const { error: creditError } = await supabase.rpc("credit_usdt_payment", {
        p_user_id: user.id,
        p_tx_hash: transfer.eventId,
        p_usdt_amount: usdtAmount,
        p_gram_amount: creditedGram,
      });

      // tx_already_used means this event was already credited — either by
      // a previous sweep pass or, in principle, the prompted verify flow
      // for the same comment — and is expected/harmless. Anything else is
      // worth knowing about.
      if (creditError && !String(creditError.message).includes("tx_already_used")) {
        console.error("USDT deposit sweep: credit failed for event", transfer.eventId, creditError);
      }
    }
  } catch (err) {
    // Never let a sweep failure break the request it piggybacked on.
    console.error("USDT deposit sweep failed:", err);
  }
}
