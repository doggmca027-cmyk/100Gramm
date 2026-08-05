import { NextRequest, NextResponse } from "next/server";
import { toNano } from "@ton/core";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const VALID_SECONDS = 10 * 60;

/**
 * Returns everything the client needs to build the TON Connect transfer for
 * a pack, computed server-side so it's guaranteed to match what
 * verify-purchase will later check: same nanoton amount (derived from the
 * same gram_packs row via the same toNano()), same comment.
 *
 * The comment embeds the caller's own session-derived user id — never
 * client-supplied — which is why this exists as a separate call instead of
 * having the client construct the comment itself from data it already has.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const packId = typeof body?.packId === "string" ? body.packId : null;

    if (!packId) {
      return NextResponse.json({ error: "invalid_pack_id" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data: pack, error } = await supabase
      .from("gram_packs")
      .select("id, title, gram_amount, price_ton")
      .eq("id", packId)
      .eq("is_active", true)
      .maybeSingle();
    if (error) throw error;
    if (!pack) {
      return NextResponse.json({ error: "unknown_pack" }, { status: 404 });
    }

    return NextResponse.json({
      packId: pack.id,
      gramAmount: pack.gram_amount,
      priceTon: pack.price_ton,
      amountNano: toNano(String(pack.price_ton)).toString(),
      comment: `${userId}:${packId}`,
      validUntil: Math.floor(Date.now() / 1000) + VALID_SECONDS,
    });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
