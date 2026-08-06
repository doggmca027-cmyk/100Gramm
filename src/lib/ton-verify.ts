import "server-only";
import { Address, Cell } from "@ton/core";

/**
 * Server-side verification for TON Connect payments, backed by TonAPI
 * (https://tonapi.io). We never trust anything the client says about a
 * payment beyond "here's roughly where to look" — the source of truth is
 * always what's actually on-chain for the treasury account.
 *
 * Verification walks the treasury wallet's own recent incoming transactions
 * (`/v2/blockchain/accounts/{treasury}/transactions`) rather than resolving
 * the boc TonConnect's sendTransaction() returns to a transaction hash.
 * That boc is the *external* message to the buyer's wallet contract; the
 * value transfer we care about is a *different*, internal message the
 * wallet emits afterwards, and mapping one to the other reliably needs
 * wallet-version-aware "normalized hash" logic. Reading the treasury's own
 * inbound history sidesteps that entirely — we know the destination, the
 * expected amount, and the exact comment we asked the buyer to attach, and
 * that combination is what we match against.
 */

export interface VerifiedPayment {
  txHash: string;
  valueNano: bigint;
}

interface TonApiMessage {
  value?: number;
  destination?: { address?: string };
  raw_body?: string;
}

interface TonApiTransaction {
  hash?: string;
  success?: boolean;
  in_msg?: TonApiMessage;
  out_msgs?: TonApiMessage[];
}

interface TonApiTransactionsResponse {
  transactions?: TonApiTransaction[];
}

function tonApiBaseUrl(): string {
  const network = process.env.TON_NETWORK ?? process.env.NEXT_PUBLIC_TON_NETWORK ?? "mainnet";
  return network === "testnet" ? "https://testnet.tonapi.io" : "https://tonapi.io";
}

async function tonApiFetch<T>(path: string, params?: Record<string, string>): Promise<T> {
  const url = new URL(path, tonApiBaseUrl());
  for (const [key, value] of Object.entries(params ?? {})) {
    url.searchParams.set(key, value);
  }

  const apiKey = process.env.TONAPI_KEY;
  const res = await fetch(url, {
    headers: apiKey ? { Authorization: `Bearer ${apiKey}` } : undefined,
    cache: "no-store",
  });

  if (!res.ok) {
    throw new Error(`tonapi_error_${res.status}`);
  }

  return res.json() as Promise<T>;
}

/** Decodes a standard TEP-0 "simple text comment" cell: uint32(0) + UTF-8 tail. */
function decodeComment(rawBodyHex: string | undefined): string | null {
  if (!rawBodyHex) return null;
  try {
    const cell = Cell.fromBoc(Buffer.from(rawBodyHex, "hex"))[0];
    const slice = cell.beginParse();
    if (slice.remainingBits < 32) return null;
    const op = slice.loadUint(32);
    if (op !== 0) return null;
    return slice.loadStringTail();
  } catch {
    return null;
  }
}

function addressesEqual(a: string | undefined, b: string): boolean {
  if (!a) return false;
  try {
    return Address.parse(a).equals(Address.parse(b));
  } catch {
    return false;
  }
}

/** Single pass over the treasury's recent outbound transactions looking for a match. */
async function findOutgoingTransaction(
  treasuryAddress: string,
  toAddress: string,
  expectedComment: string,
): Promise<VerifiedPayment | null> {
  const encodedAccount = encodeURIComponent(treasuryAddress);
  const data = await tonApiFetch<TonApiTransactionsResponse>(
    `/v2/blockchain/accounts/${encodedAccount}/transactions`,
    { limit: "20", sort_order: "desc" },
  );

  for (const tx of data.transactions ?? []) {
    if (!tx.success || !tx.hash) continue;

    for (const msg of tx.out_msgs ?? []) {
      if (!addressesEqual(msg.destination?.address, toAddress)) continue;
      if (decodeComment(msg.raw_body) !== expectedComment) continue;

      return { txHash: tx.hash, valueNano: BigInt(Math.trunc(msg.value ?? 0)) };
    }
  }

  return null;
}

/**
 * Polls TonAPI for the treasury's own outgoing payout matching
 * `toAddress` + `expectedComment` — used after the server itself broadcasts
 * a withdrawal payout (see ton-wallet-sender.ts) to recover the resulting
 * transaction hash for the audit trail. Same "never throws, null means not
 * indexed yet" contract as pollForTreasuryPayment.
 */
export async function pollForOutgoingPayment(
  treasuryAddress: string,
  toAddress: string,
  expectedComment: string,
  { attempts = 4, delayMs = 2000 }: { attempts?: number; delayMs?: number } = {},
): Promise<VerifiedPayment | null> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const match = await findOutgoingTransaction(treasuryAddress, toAddress, expectedComment);
      if (match) return match;
    } catch (err) {
      console.error("TonAPI outgoing-payment poll failed:", err);
    }

    if (attempt < attempts - 1) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }

  return null;
}

/** Single pass over the treasury's recent inbound transactions looking for a match. */
async function findMatchingTransaction(
  treasuryAddress: string,
  expectedNano: bigint,
  expectedComment: string,
): Promise<VerifiedPayment | null> {
  const encodedAccount = encodeURIComponent(treasuryAddress);
  const data = await tonApiFetch<TonApiTransactionsResponse>(
    `/v2/blockchain/accounts/${encodedAccount}/transactions`,
    { limit: "20", sort_order: "desc" },
  );

  for (const tx of data.transactions ?? []) {
    const msg = tx.in_msg;
    if (!tx.success || !msg || !tx.hash) continue;
    if (!addressesEqual(msg.destination?.address, treasuryAddress)) continue;

    const valueNano = BigInt(Math.trunc(msg.value ?? 0));
    if (valueNano < expectedNano) continue;

    const comment = decodeComment(msg.raw_body);
    if (comment !== expectedComment) continue;

    return { txHash: tx.hash, valueNano };
  }

  return null;
}

/**
 * Polls TonAPI for a treasury payment matching `expectedComment` and
 * `expectedNano` (or more — overpaying is accepted, never partial credit).
 * Kept short (a few seconds) on purpose to stay well inside serverless
 * function time limits — this is one attempt within the client's own retry
 * loop (see verifyTonDeposit in api-client.ts), not the only attempt.
 * Returns null (never throws) when nothing matches yet — the caller should
 * treat that as "not confirmed on-chain yet, ask the client to retry" rather
 * than "invalid".
 */
export async function pollForTreasuryPayment(
  treasuryAddress: string,
  expectedNano: bigint,
  expectedComment: string,
  { attempts = 3, delayMs = 2000 }: { attempts?: number; delayMs?: number } = {},
): Promise<VerifiedPayment | null> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const match = await findMatchingTransaction(treasuryAddress, expectedNano, expectedComment);
      if (match) return match;
    } catch (err) {
      // Transient TonAPI hiccup — log and keep polling rather than failing
      // the whole purchase on one bad response.
      console.error("TonAPI poll failed:", err);
    }

    if (attempt < attempts - 1) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }

  return null;
}

/**
 * Deterministically resolves `owner`'s Jetton-wallet address for
 * `jettonMaster`, via TonAPI's generic get-method executor calling the
 * master contract's own `get_wallet_address`. This works even for an owner
 * that has never held the jetton before (unlike TonAPI's
 * /accounts/{a}/jettons/{j} lookup, which 404s until a wallet has actually
 * been indexed) — the address is pure CREATE2-style computation from the
 * master's state + owner address, no on-chain deploy required to know it.
 * Needed both for the treasury (to know where to poll) and for the buyer
 * (that's the actual `to:` a TON Connect Jetton transfer message goes to).
 */
export async function resolveJettonWalletAddress(
  jettonMaster: string,
  owner: string,
): Promise<string | null> {
  try {
    const encodedMaster = encodeURIComponent(jettonMaster);
    const data = await tonApiFetch<{
      success?: boolean;
      decoded?: { jetton_wallet_address?: string };
    }>(`/v2/blockchain/accounts/${encodedMaster}/methods/get_wallet_address`, { args: owner });

    const raw = data.decoded?.jetton_wallet_address;
    if (!data.success || !raw) return null;
    return Address.parse(raw).toString();
  } catch (err) {
    console.error("TonAPI get_wallet_address failed:", err);
    return null;
  }
}

interface TonApiJettonTransferAction {
  type?: string;
  status?: string;
  JettonTransfer?: {
    recipient?: { address?: string };
    amount?: string;
    comment?: string;
    jetton?: { address?: string };
  };
}

interface TonApiEvent {
  event_id?: string;
  actions?: TonApiJettonTransferAction[];
}

interface TonApiEventsResponse {
  events?: TonApiEvent[];
}

export interface JettonTransferEvent {
  /** Stable per on-chain event — fills the "idempotency key for credit_usdt_payment's unique tx_hash" role. */
  eventId: string;
  /** Decoded forward_payload text comment, if the sender attached one — null means no memo, unmatchable to any user. */
  comment: string | null;
  units: bigint;
}

/**
 * All recent incoming `jettonMaster` transfers to `treasuryOwnerAddress`,
 * newest first. The building block for both findMatchingJettonTransfer
 * (knows what it's looking for in advance — a prompted payment) and the
 * passive deposit sweep (lib/usdt-deposit-sweep.ts — doesn't know who's
 * paying until it reads each transfer's own comment).
 */
async function fetchRecentJettonTransfers(
  treasuryOwnerAddress: string,
  jettonMaster: string,
  limit = 30,
): Promise<JettonTransferEvent[]> {
  const encodedAccount = encodeURIComponent(treasuryOwnerAddress);
  const data = await tonApiFetch<TonApiEventsResponse>(`/v2/accounts/${encodedAccount}/events`, {
    limit: String(limit),
  });

  const results: JettonTransferEvent[] = [];
  for (const event of data.events ?? []) {
    if (!event.event_id) continue;
    for (const action of event.actions ?? []) {
      if (action.type !== "JettonTransfer" || action.status !== "ok") continue;
      const transfer = action.JettonTransfer;
      if (!transfer) continue;
      if (!addressesEqual(transfer.jetton?.address, jettonMaster)) continue;
      if (!addressesEqual(transfer.recipient?.address, treasuryOwnerAddress)) continue;

      results.push({
        eventId: event.event_id,
        comment: transfer.comment ?? null,
        units: BigInt(transfer.amount ?? "0"),
      });
    }
  }
  return results;
}

/**
 * Every recent incoming `jettonMaster` transfer to `treasuryOwnerAddress` —
 * used by the passive deposit sweep, which (unlike
 * pollForTreasuryJettonPayment) doesn't know in advance which comment or
 * amount to expect and has to read every transfer's own memo to figure out
 * who it belongs to.
 */
export async function fetchRecentJettonTransfersToTreasury(
  treasuryOwnerAddress: string,
  jettonMaster: string,
  limit = 30,
): Promise<JettonTransferEvent[]> {
  return fetchRecentJettonTransfers(treasuryOwnerAddress, jettonMaster, limit);
}

/** Single pass over the treasury owner account's recent decoded events looking for a matching Jetton transfer. */
async function findMatchingJettonTransfer(
  treasuryOwnerAddress: string,
  jettonMaster: string,
  expectedUnits: bigint,
  expectedComment: string,
): Promise<VerifiedPayment | null> {
  const transfers = await fetchRecentJettonTransfers(treasuryOwnerAddress, jettonMaster);
  for (const transfer of transfers) {
    if (transfer.comment !== expectedComment) continue;
    if (transfer.units < expectedUnits) continue;
    return { txHash: transfer.eventId, valueNano: transfer.units };
  }
  return null;
}

/**
 * Polls TonAPI for an incoming Jetton transfer to `treasuryOwnerAddress`
 * matching `jettonMaster` + `expectedComment`, for at least `expectedUnits`
 * (base jetton units — 6 decimals for USDT). Same "never throws, null means
 * not indexed/found yet" contract as pollForTreasuryPayment.
 */
export async function pollForTreasuryJettonPayment(
  treasuryOwnerAddress: string,
  jettonMaster: string,
  expectedUnits: bigint,
  expectedComment: string,
  { attempts = 3, delayMs = 2000 }: { attempts?: number; delayMs?: number } = {},
): Promise<VerifiedPayment | null> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const match = await findMatchingJettonTransfer(
        treasuryOwnerAddress,
        jettonMaster,
        expectedUnits,
        expectedComment,
      );
      if (match) return match;
    } catch (err) {
      console.error("TonAPI jetton poll failed:", err);
    }

    if (attempt < attempts - 1) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }

  return null;
}
