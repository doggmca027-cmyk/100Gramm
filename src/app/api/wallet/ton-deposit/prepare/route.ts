import { NextRequest, NextResponse } from "next/server";
import { toNano } from "@ton/core";
import { requireUserId } from "@/lib/session";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const VALID_SECONDS = 10 * 60;

/** 1 GRAM = 1 TON, so this is really just "don't let a dust transfer through". */
const MIN_DEPOSIT_TON = 0.05;

/**
 * Returns what the client needs to build the TON Connect transfer for a
 * direct deposit: the nanoton amount and the comment to attach. The comment
 * embeds the caller's own session-derived user id — never client-supplied —
 * which is why this exists as a separate call instead of having the client
 * construct the comment itself from data it already has.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const amountTon = Number(body?.amountTon);

    if (!Number.isFinite(amountTon) || amountTon < MIN_DEPOSIT_TON) {
      return NextResponse.json({ error: "amount_too_low", min: MIN_DEPOSIT_TON }, { status: 400 });
    }

    return NextResponse.json({
      amountNano: toNano(String(amountTon)).toString(),
      comment: userId,
      validUntil: Math.floor(Date.now() / 1000) + VALID_SECONDS,
    });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
