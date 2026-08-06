import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * GRAM *is* TON (see 0024_ton_deposit_1to1.sql) — so "GRAM/USDT" is really
 * just live TON/USDT, fetched from TonAPI's /v2/rates and cached in the
 * `exchange_rates` table for up to RATE_STALE_MS so no request pays the
 * latency (or risk) of an outbound HTTP call more than once a minute.
 * DEFAULT_RATE is only ever used the very first time this table is empty —
 * it's seeded by the migration, so in practice this is dead code except as
 * a last-resort fallback if TonAPI is down *and* the row somehow got wiped.
 */

const PAIR = "GRAM_USDT";
export const RATE_STALE_MS = 60_000;
export const DEFAULT_GRAM_USDT_RATE = 1.4;

export interface ExchangeRate {
  rate: number;
  updatedAt: string;
  source: string;
  stale: boolean;
}

function tonApiBaseUrl(): string {
  const network = process.env.TON_NETWORK ?? process.env.NEXT_PUBLIC_TON_NETWORK ?? "mainnet";
  return network === "testnet" ? "https://testnet.tonapi.io" : "https://tonapi.io";
}

/** Null on any failure — callers fall back to whatever's cached rather than propagating. */
async function fetchLiveTonUsdRate(): Promise<number | null> {
  try {
    const url = new URL("/v2/rates", tonApiBaseUrl());
    url.searchParams.set("tokens", "ton");
    url.searchParams.set("currencies", "usd");

    const apiKey = process.env.TONAPI_KEY;
    const res = await fetch(url, {
      headers: apiKey ? { Authorization: `Bearer ${apiKey}` } : undefined,
      cache: "no-store",
    });
    if (!res.ok) return null;

    const data = (await res.json()) as { rates?: { TON?: { prices?: { USD?: number } } } };
    const price = data.rates?.TON?.prices?.USD;
    return typeof price === "number" && price > 0 ? price : null;
  } catch (err) {
    console.error("TonAPI rate fetch failed:", err);
    return null;
  }
}

/**
 * Reads the cached rate; refreshes it from TonAPI first if it's older than
 * RATE_STALE_MS. Never throws — a failed live fetch just falls back to
 * whatever's still cached (or DEFAULT_GRAM_USDT_RATE if the table is
 * somehow empty), so a TonAPI outage degrades to "slightly stale price"
 * rather than breaking deposits/purchases.
 */
export async function getGramUsdtRate(supabase: SupabaseClient): Promise<ExchangeRate> {
  const { data: cached } = await supabase
    .from("exchange_rates")
    .select("rate, source, updated_at")
    .eq("pair", PAIR)
    .maybeSingle();

  const ageMs = cached ? Date.now() - new Date(cached.updated_at).getTime() : Infinity;
  if (cached && ageMs < RATE_STALE_MS) {
    return { rate: cached.rate, updatedAt: cached.updated_at, source: cached.source, stale: false };
  }

  const live = await fetchLiveTonUsdRate();
  if (live != null) {
    const { data: updated, error } = await supabase.rpc("set_exchange_rate", {
      p_pair: PAIR,
      p_rate: live,
      p_source: "tonapi",
    });
    if (!error && updated) {
      return { rate: live, updatedAt: new Date().toISOString(), source: "tonapi", stale: false };
    }
  }

  // Live fetch failed (or the write-back did) — serve the stale cache
  // rather than fail the request outright.
  if (cached) {
    return { rate: cached.rate, updatedAt: cached.updated_at, source: cached.source, stale: true };
  }
  return { rate: DEFAULT_GRAM_USDT_RATE, updatedAt: new Date().toISOString(), source: "default", stale: true };
}
