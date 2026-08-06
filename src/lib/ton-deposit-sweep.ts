import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import { fromNano } from "@ton/core";
import { fetchRecentIncomingTonTransfersToTreasury } from "./ton-verify";

/**
 * Passive counterpart to the prompted TON Connect deposit flow (prepare +
 * verify, triggered right after sendTransaction) — catches native TON sent
 * straight to the treasury address from *any* wallet or exchange, matching
 * the same manual-requisites idea the USDT tab already has (see
 * lib/usdt-deposit-sweep.ts, which this mirrors almost exactly). Reads the
 * treasury's recent incoming transfers, and for each one not already in
 * wallet_transactions, resolves the sender by their comment (the payer's
 * own Telegram id) and credits it 1:1 via credit_ton_deposit
 * (0024_ton_deposit_1to1.sql) — same table, same tx_hash uniqueness guard,
 * so this is safe to run even for transfers the explicit verify flow
 * already credited (the second attempt just no-ops on tx_already_used).
 *
 * Throttled to at most once per MIN_SWEEP_INTERVAL_SECONDS under its own
 * 'ton' slot (see try_claim_deposit_sweep_slot,
 * 0033_ton_deposit_sweep_and_generic_slots.sql) — independent of the USDT
 * sweep's 'usdt' slot, so neither currency's scan starves the other.
 */

const MIN_SWEEP_INTERVAL_SECONDS = 30;
/** Mirrors MIN_DEPOSIT_TON in the prompted TON deposit flow (prepare/route.ts). */
const MIN_TON_AMOUNT = 0.05;

export async function sweepTonDeposits(supabase: SupabaseClient): Promise<void> {
  const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
  if (!treasuryAddress) return;

  try {
    const { data: claimed, error: claimError } = await supabase.rpc("try_claim_deposit_sweep_slot", {
      p_kind: "ton",
      p_min_interval_seconds: MIN_SWEEP_INTERVAL_SECONDS,
    });
    if (claimError || !claimed) return;

    const transfers = await fetchRecentIncomingTonTransfersToTreasury(treasuryAddress);
    if (transfers.length === 0) return;

    for (const transfer of transfers) {
      const amountTon = Number(fromNano(transfer.valueNano));
      if (amountTon < MIN_TON_AMOUNT) continue;

      // The memo is expected to be a bare Telegram id (same convention as
      // both the prompted TON deposit and the USDT sweep) — anything else
      // can't be matched to a user and is left for manual admin
      // reconciliation rather than guessed at.
      const telegramId = transfer.comment?.trim();
      if (!telegramId || !/^\d+$/.test(telegramId)) continue;

      const { data: user } = await supabase
        .from("users")
        .select("id")
        .eq("telegram_id", telegramId)
        .maybeSingle();
      if (!user) continue;

      const { error: creditError } = await supabase.rpc("credit_ton_deposit", {
        p_user_id: user.id,
        p_tx_hash: transfer.txHash,
        p_amount_ton: amountTon,
      });

      // tx_already_used means this transfer was already credited — either
      // by a previous sweep pass or the prompted verify flow for the same
      // send — and is expected/harmless. Anything else is worth knowing about.
      if (creditError && !String(creditError.message).includes("tx_already_used")) {
        console.error("TON deposit sweep: credit failed for tx", transfer.txHash, creditError);
      }
    }
  } catch (err) {
    // Never let a sweep failure break the request it piggybacked on.
    console.error("TON deposit sweep failed:", err);
  }
}
