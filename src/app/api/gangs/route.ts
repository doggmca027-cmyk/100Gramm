import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

/**
 * Browse-to-join list AND the "Топ Банд Района" ranking table share this
 * one endpoint — both read get_gangs (0058_gangs.sql), which is always
 * ordered level desc, experience desc; `q` just narrows it by name instead
 * of changing the order.
 */
export async function GET(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const search = request.nextUrl.searchParams.get("q");

    const supabase = supabaseServer();
    const { data, error } = await supabase.rpc("get_gangs", {
      p_user_id: userId,
      p_search: search,
    });
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}

/**
 * Founds a gang for exactly 5 GRAM ("5 TON", see create_gang's comment in
 * 0058_gangs.sql for why there's no separate TON balance). Every rule —
 * name length/charset/profanity, uniqueness, balance, "not already in a
 * gang" — is re-checked strictly server-side inside the RPC regardless of
 * what the create-gang modal already validated client-side.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);

    const name = typeof body?.name === "string" ? body.name : "";
    const avatarId = typeof body?.avatarId === "string" ? body.avatarId : "default_gang";

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("create_gang", {
      p_user_id: userId,
      p_name: name,
      p_avatar_id: avatarId,
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
