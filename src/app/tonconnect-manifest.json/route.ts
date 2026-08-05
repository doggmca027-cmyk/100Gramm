import { NextResponse } from "next/server";

/**
 * TON Connect manifest (https://github.com/ton-blockchain/ton-connect/blob/main/spec/manifest.md).
 * Wallets fetch this over HTTPS and require every URL inside to be absolute
 * and to actually match the deployed origin — so it's served dynamically
 * from NEXT_PUBLIC_APP_URL instead of a static /public file that's easy to
 * forget updating per-environment (preview deploys, staging, prod).
 */
export const dynamic = "force-static";

export async function GET() {
  const appUrl = (process.env.NEXT_PUBLIC_APP_URL ?? "").replace(/\/+$/, "");

  if (!appUrl) {
    return NextResponse.json(
      { error: "NEXT_PUBLIC_APP_URL is not set — required to build tonconnect-manifest.json" },
      { status: 500 },
    );
  }

  return NextResponse.json({
    url: appUrl,
    name: "100ГРАМ",
    // Reuses the existing in-app coin art — swap for a dedicated square
    // app icon (recommended 180x180 PNG) if/when one exists.
    iconUrl: `${appUrl}/products/gram-coin.jpg`,
  });
}
