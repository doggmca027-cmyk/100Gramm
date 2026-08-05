import "server-only";
import {
  Address,
  TonClient,
  WalletContractV3R2,
  WalletContractV4,
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

// v5r1 isn't supported here — its sendTransfer() needs an extra `authType`
// field that doesn't line up with the v3r2/v4 call shape below. Those two
// cover the overwhelming majority of wallets; a hot wallet dedicated to
// this purpose can simply be a fresh v4 wallet if the real treasury
// happens to be v5r1.
type WalletVersion = "v3r2" | "v4";

interface TreasuryWallet {
  contract: WalletContractV3R2 | WalletContractV4;
  secretKey: Buffer;
}

let cachedWallet: TreasuryWallet | null = null;
let cachedClient: TonClient | null = null;

function tonCenterEndpoint(): string {
  const network = process.env.TON_NETWORK ?? process.env.NEXT_PUBLIC_TON_NETWORK ?? "mainnet";
  return network === "testnet"
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
 * a wallet-version mismatch (v3r2 vs v4) derives a *different* address from
 * the same mnemonic, so this check is what turns "silently pays out of thin
 * air / to nowhere" into a loud startup error instead. Cached after the
 * first successful call (mnemonic-to-keypair is a deliberately slow KDF).
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

  const contract =
    version === "v3r2"
      ? WalletContractV3R2.create({ workchain: 0, publicKey: keyPair.publicKey })
      : WalletContractV4.create({ workchain: 0, publicKey: keyPair.publicKey });

  if (!contract.address.equals(Address.parse(expectedAddress))) {
    throw new Error(
      `treasury_wallet_address_mismatch: mnemonic derives ${contract.address.toString()} as ${version}, ` +
        `expected ${expectedAddress}. Set TREASURY_WALLET_VERSION to whichever of v3r2/v4 matches the real ` +
        `treasury wallet's contract type.`,
    );
  }

  cachedWallet = { contract, secretKey: keyPair.secretKey };
  return cachedWallet;
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
  const { contract, secretKey } = await getTreasuryWallet();
  const client = getClient();
  const opened = client.open(contract);

  // A wallet contract's external message can be accepted (seqno
  // increments) even when it can't actually afford the enclosed transfer —
  // that failure only shows up on-chain later, not as an exception here.
  // Checking the balance up front catches the single most likely real
  // failure mode (treasury underfunded) before we ever broadcast, rather
  // than leaving it to a later reconciliation.
  const requiredNano = toNano(String(amountTon)) + toNano("0.05"); // + network fee buffer
  const balanceNano = await opened.getBalance();
  if (balanceNano < requiredNano) {
    throw new Error("insufficient_treasury_balance");
  }

  const seqno = await opened.getSeqno();

  await opened.sendTransfer({
    seqno,
    secretKey,
    messages: [
      internal({
        to: Address.parse(toAddress),
        value: toNano(String(amountTon)),
        bounce: false,
        body: comment(memo),
      }),
    ],
  });

  const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET!;
  const payment = await pollForOutgoingPayment(treasuryAddress, toAddress, memo);
  return { txHash: payment?.txHash ?? null };
}
