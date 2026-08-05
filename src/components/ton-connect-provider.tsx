"use client";

import { TonConnectUIProvider } from "@tonconnect/ui-react";

/**
 * Wraps the app with TON Connect. Split out from layout.tsx (a server
 * component) because TonConnectUIProvider is client-only — it touches
 * `window`/localStorage to restore the wallet session on mount.
 *
 * MUST always render <TonConnectUIProvider> — never skip it. Every
 * useTonConnectUI()/useTonAddress()/useTonWallet() call (BalanceScreen,
 * WalletConnectModal) throws TonConnectProviderNotSetError
 * synchronously if no provider is mounted above it, which crashes the
 * whole render tree (this previously took down the entire Balance tab
 * whenever NEXT_PUBLIC_APP_URL wasn't set in the deployment's env vars).
 *
 * manifestUrl points at our own dynamic route (src/app/tonconnect-manifest.json/route.ts),
 * which derives the origin from the incoming request — so this never
 * depends on NEXT_PUBLIC_APP_URL being configured at all. window.location.origin
 * here is just the same idea applied client-side.
 */
export function TonConnectProvider({ children }: { children: React.ReactNode }) {
  const appUrl =
    process.env.NEXT_PUBLIC_APP_URL || (typeof window !== "undefined" ? window.location.origin : "");

  return (
    <TonConnectUIProvider manifestUrl={`${appUrl}/tonconnect-manifest.json`}>
      {children}
    </TonConnectUIProvider>
  );
}
