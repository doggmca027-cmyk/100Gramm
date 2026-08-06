import { Address, beginCell, type Cell } from "@ton/core";

/**
 * Tether USD₮ Jetton master on TON mainnet. Overridable via env for a
 * testnet deployment (the mainnet address is meaningless there) — falls
 * back to the real mainnet contract otherwise.
 */
export const USDT_JETTON_MASTER =
  process.env.NEXT_PUBLIC_USDT_JETTON_MASTER ?? "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs";

export const USDT_DECIMALS = 6;

/**
 * TON Connect message `value` for the jetton transfer — must cover the
 * buyer's own jetton wallet's execution gas *plus* forward_ton_amount
 * (which travels onward with the notification). USDT's jetton wallet is on
 * the heavier side gas-wise, so this is intentionally generous; unused TON
 * is refunded back to the buyer, never lost.
 */
export const JETTON_TRANSFER_GAS_NANO = BigInt(150_000_000); // 0.15 TON
/** Forwarded on to the treasury with the notification — must stay well under JETTON_TRANSFER_GAS_NANO. */
export const JETTON_FORWARD_TON_NANO = BigInt(20_000_000); // 0.02 TON

/** ceil() so the payer's wallet never sends fractionally *less* than the quoted USDT amount. */
export function usdtToUnits(usdtAmount: number): bigint {
  return BigInt(Math.ceil(usdtAmount * 10 ** USDT_DECIMALS));
}

export function unitsToUsdt(units: bigint): number {
  return Number(units) / 10 ** USDT_DECIMALS;
}

const JETTON_TRANSFER_OP = 0x0f8a7ea5;

/**
 * TEP-74 `transfer` message body for a buyer's Jetton wallet. Isomorphic
 * (no server-only tag) — built client-side right before
 * tonConnectUI.sendTransaction, same as buildCommentPayload in
 * wallet-modal.tsx builds the native-TON comment payload.
 *
 * forward_ton_amount must be > 0 for the buyer's wallet to forward
 * forward_payload on to `destination` as a jetton_transfer_notification —
 * that's the message TonAPI decodes into the `comment` field our server-side
 * poll matches on (see ton-verify.ts's findMatchingJettonTransfer).
 */
export function buildJettonTransferBody(params: {
  jettonAmountUnits: bigint;
  /** Owner who should end up holding the jettons — the treasury's own TON address, not its jetton wallet. */
  destination: string;
  /** Where any excess/leftover TON from this message gets refunded — the buyer's own address. */
  responseDestination: string;
  forwardTonAmountNano: bigint;
  /** Becomes forward_payload as a plain TEP-0 text comment — what the server matches on and credits against. */
  comment: string;
  queryId?: bigint;
}): Cell {
  const forwardPayload = beginCell().storeUint(0, 32).storeStringTail(params.comment).endCell();

  return beginCell()
    .storeUint(JETTON_TRANSFER_OP, 32)
    .storeUint(params.queryId ?? BigInt(0), 64)
    .storeCoins(params.jettonAmountUnits)
    .storeAddress(Address.parse(params.destination))
    .storeAddress(Address.parse(params.responseDestination))
    .storeBit(0) // no custom_payload
    .storeCoins(params.forwardTonAmountNano)
    .storeBit(1) // forward_payload carried as a reference (safest for arbitrary-length text)
    .storeRef(forwardPayload)
    .endCell();
}
