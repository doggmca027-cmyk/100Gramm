import type { TonConnectUI } from "@tonconnect/ui-react";

/**
 * Every "Connect wallet" button in the app calls tonConnectUI.openModal()
 * without awaiting or catching it — if it rejects (transient network blip
 * fetching the wallets registry, a stuck pairing session left over from a
 * previous failed attempt, etc.) the promise just dies as an unhandled
 * rejection and the user sees the button do nothing, with zero feedback.
 * Reported for real by multiple users trying different wallets (Volt,
 * Tonkeeper) — not wallet-specific, this call site pattern is the common
 * thread. Wrap it so callers can surface *something* instead of silence.
 */
export async function openTonConnectModal(tonConnectUI: TonConnectUI): Promise<void> {
  try {
    await tonConnectUI.openModal();
  } catch (err) {
    console.error("tonConnectUI.openModal() failed:", err);
    throw err;
  }
}
