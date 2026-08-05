import { NextRequest, NextResponse } from "next/server";

/**
 * TON Connect manifest (https://github.com/ton-blockchain/ton-connect/blob/main/spec/manifest.md).
 * Wallets fetch this over HTTPS and require every URL inside to be absolute
 * and to actually match the deployed origin. Derived from the incoming
 * request's own origin rather than NEXT_PUBLIC_APP_URL, so it's correct on
 * every environment (prod/staging/preview) with zero config — a missing env
 * var here previously meant a broken manifest, which is exactly the kind of
 * misconfiguration that must never be able to crash the app (see
 * ton-connect-provider.tsx).
 */
export async function GET(request: NextRequest) {
  const appUrl = request.nextUrl.origin;

  return NextResponse.json({
    url: appUrl,
    name: "100ГРАМ",
    // Reuses the existing in-app coin art — swap for a dedicated square
    // app icon (recommended 180x180 PNG) if/when one exists.
    iconUrl: `${appUrl}/products/gram-coin.jpg`,
  });
}
