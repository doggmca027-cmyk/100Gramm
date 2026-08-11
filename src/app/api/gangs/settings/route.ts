import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/** Leader-only: closed/open toggle, entry price, description — see update_gang_settings (0078_gang_closed_paid_description.sql). */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const isClosed = body?.isClosed === true;
    const entryPriceGram = Number(body?.entryPriceGram);
    const description = typeof body?.description === "string" ? body.description : "";

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("update_gang_settings", {
      p_user_id: userId,
      p_is_closed: isClosed,
      p_entry_price_gram: Number.isFinite(entryPriceGram) ? entryPriceGram : 0,
      p_description: description,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ result, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
