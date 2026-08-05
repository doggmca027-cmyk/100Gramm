"use client";

import { TonConnectUIProvider } from "@tonconnect/ui-react";

/**
 * Wraps the app with TON Connect. Split out from layout.tsx (a server
 * component) because TonConnectUIProvider is client-only — it touches
 * `window`/localStorage to restore the wallet session on mount.
 *
 * manifestUrl points at our own dynamic route (src/app/tonconnect-manifest.json/route.ts)
 * rather than a static /public file, so it always reflects NEXT_PUBLIC_APP_URL
 * for the environment actually running (prod/staging/preview).
 */
export function TonConnectProvider({ children }: { children: React.ReactNode }) {
  const appUrl = process.env.NEXT_PUBLIC_APP_URL;

  // No treasury/manifest configured yet (e.g. local dev without .env set up)
  // — render children without TON Connect rather than crashing the whole app.
  if (!appUrl) {
    return <>{children}</>;
  }

  return (
    <TonConnectUIProvider manifestUrl={`${appUrl}/tonconnect-manifest.json`}>
      {children}
    </TonConnectUIProvider>
  );
}
