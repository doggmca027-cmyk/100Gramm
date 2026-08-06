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
    // Dedicated 256x256 PNG (~90KB) — the coin art it's cropped from is a
    // ~1.4MB JPEG, which some wallet clients (reported: Volt) apparently
    // fail to fetch/render in time during pairing, breaking the connect
    // flow. Manifest icons should be small; see generate script comment
    // below if this ever needs regenerating from fresh art.
    iconUrl: `${appUrl}/tonconnect-icon.png`,
  });
}
