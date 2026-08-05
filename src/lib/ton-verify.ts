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
