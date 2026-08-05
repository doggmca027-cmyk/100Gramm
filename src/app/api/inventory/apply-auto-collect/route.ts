import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const itemType = typeof body?.itemType === "string" ? body.itemType : null;

    if (!itemType) {
      return NextResponse.json({ error: "invalid_request" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { error } = await supabase.rpc("apply_auto_collect_item", {
      p_user_id: userId,
      p_item_type: itemType,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
