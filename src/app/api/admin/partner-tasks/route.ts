import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { parseChannelUsername } from "@/lib/admin";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const supabase = supabaseServer();

    const { data: seasonId, error: seasonError } = await supabase.rpc("active_season_id");
    if (seasonError) throw seasonError;

    const { data, error } = await supabase
      .from("partner_tasks")
      .select("id, title, description, reward_amount, channel_username, is_active, sort_order")
      .eq("season_id", seasonId)
      .order("sort_order");
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const body = await request.json().catch(() => null);

    const title = typeof body?.title === "string" ? body.title.trim() : "";
    const reward = Number(body?.reward);
    const username = typeof body?.channelLink === "string"
      ? parseChannelUsername(body.channelLink)
      : null;

    if (!title) {
      return NextResponse.json({ error: "missing_title" }, { status: 400 });
    }
    if (!Number.isFinite(reward) || reward <= 0) {
      return NextResponse.json({ error: "invalid_reward" }, { status: 400 });
    }
    if (!username) {
      return NextResponse.json({ error: "invalid_channel_link" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data: seasonId, error: seasonError } = await supabase.rpc("active_season_id");
    if (seasonError) throw seasonError;
    if (!seasonId) {
      return NextResponse.json({ error: "no_active_season" }, { status: 409 });
    }

    const { count } = await supabase
      .from("partner_tasks")
      .select("id", { count: "exact", head: true })
      .eq("season_id", seasonId);

    const { data, error } = await supabase
      .from("partner_tasks")
      .insert({
        season_id: seasonId,
        title,
        reward_amount: reward,
        channel_username: username,
        channel_id: `@${username}`,
        sort_order: count ?? 0,
      })
      .select()
      .single();
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
