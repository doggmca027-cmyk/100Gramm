import { NextRequest, NextResponse } from "next/server";
import { toNano } from "@ton/core";
import { requireUserId, getTelegramId } from "@/lib/session";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const VALID_SECONDS = 10 * 60;

/** 1 GRAM = 1 TON, so this is really just "don't let a dust transfer through". */
const MIN_DEPOSIT_TON = 0.05;

/**
 * Returns what the client needs to build the TON Connect transfer for a
 * direct deposit: the nanoton amount and the comment to attach. The comment
 * is the caller's own Telegram id — resolved server-side from the session,
 * never client-supplied — chosen over the internal Supabase user id so
 * it's readable at a glance (same identity already shown to admins on
 * withdrawal requests) if anyone ever needs to reconcile transfers by hand
 * against a block explorer.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const amountTon = Number(body?.amountTon);

    if (!Number.isFinite(amountTon) || amountTon < MIN_DEPOSIT_TON) {
      return NextResponse.json({ error: "amount_too_low", min: MIN_DEPOSIT_TON }, { status: 400 });
    }

    const telegramId = await getTelegramId(userId);

    return NextResponse.json({
      amountNano: toNano(String(amountTon)).toString(),
      comment: telegramId,
      validUntil: Math.floor(Date.now() / 1000) + VALID_SECONDS,
    });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
