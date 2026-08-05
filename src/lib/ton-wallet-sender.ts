import "server-only";
import {
  Address,
  SendMode,
  TonClient,
  WalletContractV3R2,
  WalletContractV4,
  WalletContractV5R1,
  comment,
  internal,
  toNano,
} from "@ton/ton";
import { mnemonicToPrivateKey } from "@ton/crypto";
import { pollForOutgoingPayment } from "./ton-verify";

/**
 * Signs and broadcasts real TON payouts from the treasury hot wallet.
 * Custody model: the treasury's 24-word mnemonic lives in TREASURY_WALLET_MNEMONIC
 * (server-only env var, never sent to the client, never logged). Whoever can
 * read that env var can drain this wallet — treat it with the same care as
 * SUPABASE_SERVICE_ROLE_KEY, and only ever keep in it what the withdrawal
 * queue is expected to need, not the project's full treasury.
 */

type WalletVersion = "v3r2" | "v4" | "v5r1";

// Kept as a discriminated union (not WalletContractV3R2 | V4 | V5R1) because
// V5R1's sendTransfer() requires a `sendMode` argument the other two don't
// (and rejects being called through a shared/union-typed handle) — the
// `version` tag is what lets sendTonPayout below dispatch to the right
// call shape without unsafe casts.
type TreasuryWallet =
  | { version: "v3r2"; contract: WalletContractV3R2; secretKey: Buffer }
  | { version: "v4"; contract: WalletContractV4; secretKey: Buffer }
  | { version: "v5r1"; contract: WalletContractV5R1; secretKey: Buffer };

let cachedWallet: TreasuryWallet | null = null;
let cachedClient: TonClient | null = null;

function tonCenterEndpoint(): string {
  const network = process.env.TON_NETWORK ?? process.env.NEXT_PUBLIC_TON_NETWORK ?? "mainnet";
  return network.toLowerCase() === "testnet"
    ? "https://testnet.toncenter.com/api/v2/jsonRPC"
    : "https://toncenter.com/api/v2/jsonRPC";
}

function getClient(): TonClient {
  if (!cachedClient) {
    cachedClient = new TonClient({
      endpoint: tonCenterEndpoint(),
      apiKey: process.env.TONCENTER_API_KEY,
    });
  }
  return cachedClient;
}

/**
 * Derives the treasury wallet contract from TREASURY_WALLET_MNEMONIC and
 * validates its address actually matches NEXT_PUBLIC_GAME_TREASURY_WALLET —
 * a wallet-version mismatch (v3r2 vs v4 vs v5r1) derives a *different*
 * address from the same mnemonic, so this check is what turns "silently
 * pays out of thin air / to nowhere" into a loud startup error instead.
 * Cached after the first successful call (mnemonic-to-keypair is a
 * deliberately slow KDF).
 */
async function getTreasuryWallet(): Promise<TreasuryWallet> {
  if (cachedWallet) return cachedWallet;

  const mnemonic = process.env.TREASURY_WALLET_MNEMONIC;
  const expectedAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
  if (!mnemonic || !expectedAddress) {
    throw new Error("treasury_wallet_not_configured");
  }

  const words = mnemonic.trim().split(/\s+/);
  if (words.length !== 24) {
    throw new Error("treasury_mnemonic_invalid_length");
  }

  const keyPair = await mnemonicToPrivateKey(words);
  const version = (process.env.TREASURY_WALLET_VERSION ?? "v4").toLowerCase() as WalletVersion;
  const target = Address.parse(expectedAddress);

  let wallet: TreasuryWallet;
  if (version === "v3r2") {
    wallet = {
      version,
      contract: WalletContractV3R2.create({ workchain: 0, publicKey: keyPair.publicKey }),
      secretKey: keyPair.secretKey,
    };
  } else if (version === "v5r1") {
    wallet = {
      version,
      contract: WalletContractV5R1.create({ workchain: 0, publicKey: keyPair.publicKey }),
      secretKey: keyPair.secretKey,
    };
  } else {
    wallet = {
      version: "v4",
      contract: WalletContractV4.create({ workchain: 0, publicKey: keyPair.publicKey }),
      secretKey: keyPair.secretKey,
    };
  }

  if (!wallet.contract.address.equals(target)) {
    throw new Error(
      `treasury_wallet_address_mismatch: mnemonic derives ${wallet.contract.address.toString()} as ${version}, ` +
        `expected ${expectedAddress}. Set TREASURY_WALLET_VERSION to whichever of v3r2/v4/v5r1 matches the ` +
        `real treasury wallet's contract type.`,
    );
  }

  cachedWallet = wallet;
  return wallet;
}

export interface PayoutResult {
  /** On-chain hash of the resulting outgoing transaction, or null if broadcast succeeded but TonAPI hadn't indexed it yet within our poll budget. */
  txHash: string | null;
}

/**
 * Sends `amountTon` from the treasury to `toAddress`, tagged with `memo`.
 * Throws only when the send itself fails (bad config, network error,
 * insufficient treasury balance) — callers must not mark anything as paid
 * out unless this resolves. A resolved call with `txHash: null` means the
 * transfer was broadcast (money is gone) but we couldn't confirm the
 * resulting hash within our poll budget; that's a bookkeeping gap, not a
 * failed payout — never retry-send on that outcome.
 */
export async function sendTonPayout(
  toAddress: string,
  amountTon: number,
  memo: string,
): Promise<PayoutResult> {
  const wallet = await getTreasuryWallet();
  const client = getClient();

  const messages = [
    internal({
      to: Address.parse(toAddress),
      value: toNano(String(amountTon)),
      bounce: false,
      body: comment(memo),
    }),
  ];

  // A wallet contract's external message can be accepted (seqno
  // increments) even when it can't actually afford the enclosed transfer —
  // that failure only shows up on-chain later, not as an exception here.
  // Checking the balance up front catches the single most likely real
  // failure mode (treasury underfunded) before we ever broadcast, rather
  // than leaving it to a later reconciliation.
  const requiredNano = toNano(String(amountTon)) + toNano("0.05"); // + network fee buffer

  if (wallet.version === "v5r1") {
    const opened = client.open(wallet.contract);
    const balanceNano = await opened.getBalance();
    if (balanceNano < requiredNano) throw new Error("insufficient_treasury_balance");
    const seqno = await opened.getSeqno();
    // v5r1's sendTransfer requires an explicit sendMode (v3r2/v4 default it
    // internally) — PAY_GAS_SEPARATELY is the standard "sender covers gas,
    // recipient gets exactly `value`" mode used for a plain transfer.
    await opened.sendTransfer({ seqno, secretKey: wallet.secretKey, messages, sendMode: SendMode.PAY_GAS_SEPARATELY });
  } else {
    const opened = client.open(wallet.contract);
    const balanceNano = await opened.getBalance();
    if (balanceNano < requiredNano) throw new Error("insufficient_treasury_balance");
    const seqno = await opened.getSeqno();
    await opened.sendTransfer({ seqno, secretKey: wallet.secretKey, messages });
  }

  const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET!;
  const payment = await pollForOutgoingPayment(treasuryAddress, toAddress, memo);
  return { txHash: payment?.txHash ?? null };
}
