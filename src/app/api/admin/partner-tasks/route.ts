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
      .select(
        "id, title, description, reward_amount, reward_item_type, reward_item_qty, channel_username, is_active, sort_order, kind, verification_method, partner_app_id, target_url",
      )
      .eq("season_id", seasonId)
      .order("sort_order");
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}

// Boost items a task can hand out instead of GRAM — kept in sync by hand
// with combo_item_templates (see lib/combo-items.ts on the client, same
// catalog the daily-combo drops and system_task_rewards pick from). Small,
// fixed, rarely-changing set — not worth a round trip to look it up.
const REWARD_ITEM_TYPES = new Set([
  "time_skip_1pct",
  "time_skip_3pct",
  "time_skip_5pct",
  "time_skip_10pct",
  "auto_collect_1d",
  "auto_collect_3d",
]);

export async function POST(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const body = await request.json().catch(() => null);

    const title = typeof body?.title === "string" ? body.title.trim() : "";
    const kind = body?.kind === "ambassador" ? "ambassador" : "partner";
    const rewardType = body?.rewardType === "item" ? "item" : "gram";
    const verificationMethod = body?.verificationMethod === "external_api" ? "external_api" : "telegram_channel";

    if (!title) {
      return NextResponse.json({ error: "missing_title" }, { status: 400 });
    }

    let reward = 0;
    let rewardItemType: string | null = null;
    let rewardItemQty = 1;

    if (rewardType === "item") {
      if (typeof body?.rewardItemType !== "string" || !REWARD_ITEM_TYPES.has(body.rewardItemType)) {
        return NextResponse.json({ error: "invalid_reward" }, { status: 400 });
      }
      rewardItemType = body.rewardItemType;
      rewardItemQty = Number(body?.rewardItemQty);
      if (!Number.isInteger(rewardItemQty) || rewardItemQty <= 0) {
        return NextResponse.json({ error: "invalid_reward" }, { status: 400 });
      }
    } else {
      reward = Number(body?.reward);
      if (!Number.isFinite(reward) || reward <= 0) {
        return NextResponse.json({ error: "invalid_reward" }, { status: 400 });
      }
    }

    const supabase = supabaseServer();

    // Fields specific to each verification method.
    let channelUsername: string | null = null;
    let channelId: string | null = null;
    let partnerAppId: string | null = null;
    let targetUrl: string | null = null;

    if (verificationMethod === "telegram_channel") {
      const username = typeof body?.channelLink === "string"
        ? parseChannelUsername(body.channelLink)
        : null;
      if (!username) {
        return NextResponse.json({ error: "invalid_channel_link" }, { status: 400 });
      }
      channelUsername = username;
      channelId = `@${username}`;
    } else {
      partnerAppId = typeof body?.partnerAppId === "string" ? body.partnerAppId : null;
      targetUrl = typeof body?.targetUrl === "string" ? body.targetUrl.trim() : "";
      if (!partnerAppId) {
        return NextResponse.json({ error: "missing_partner_app" }, { status: 400 });
      }
      if (!targetUrl || !/^https?:\/\//.test(targetUrl)) {
        return NextResponse.json({ error: "invalid_target_url" }, { status: 400 });
      }
      const { data: partnerApp, error: partnerAppError } = await supabase
        .from("partner_apps")
        .select("id")
        .eq("id", partnerAppId)
        .eq("is_active", true)
        .maybeSingle();
      if (partnerAppError) throw partnerAppError;
      if (!partnerApp) {
        return NextResponse.json({ error: "unknown_partner_app" }, { status: 400 });
      }
    }

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
        reward_item_type: rewardItemType,
        reward_item_qty: rewardItemQty,
        channel_username: channelUsername,
        channel_id: channelId,
        sort_order: count ?? 0,
        kind,
        verification_method: verificationMethod,
        partner_app_id: partnerAppId,
        target_url: targetUrl,
      })
      .select()
      .single();
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
