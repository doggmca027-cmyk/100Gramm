import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const MEMBER_STATUSES = new Set(["member", "administrator", "creator"]);

/**
 * Claims a system task's reward (see 0028_system_tasks.sql — items + XP,
 * never GRAM). Referral/gameplay tasks are verified entirely inside the
 * claim_system_task RPC (internal data, no external call needed). Social
 * tasks with a real Telegram check (channel_sub/chat_join) are verified
 * *here*, before the RPC is ever called — same trust boundary as
 * /api/tasks/check-sub for partner_tasks. post_view has nothing Telegram
 * exposes to verify "viewed a post" with, so it's a self-report by design.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const slug = typeof body?.slug === "string" ? body.slug : null;
    if (!slug) {
      return NextResponse.json({ error: "unknown_task" }, { status: 400 });
    }

    const supabase = supabaseServer();

    const { data: task, error: taskError } = await supabase
      .from("system_tasks")
      .select("category, target_type, target_value, is_active")
      .eq("slug", slug)
      .maybeSingle();
    if (taskError) throw taskError;
    if (!task || !task.is_active) {
      return NextResponse.json({ error: "unknown_task" }, { status: 404 });
    }

    if (task.category === "social" && (task.target_type === "channel_sub" || task.target_type === "chat_join")) {
      if (!task.target_value) {
        return NextResponse.json({ error: "task_not_configured" }, { status: 409 });
      }

      const botToken = process.env.TELEGRAM_BOT_TOKEN;
      if (!botToken) {
        return NextResponse.json({ error: "server_misconfigured" }, { status: 500 });
      }

      const { data: userRow, error: userError } = await supabase
        .from("users")
        .select("telegram_id")
        .eq("id", userId)
        .single();
      if (userError || !userRow) {
        return NextResponse.json({ error: "unknown_user" }, { status: 404 });
      }

      const tgRes = await fetch(
        `https://api.telegram.org/bot${botToken}/getChatMember` +
          `?chat_id=${encodeURIComponent(task.target_value)}&user_id=${userRow.telegram_id}`,
      );
      const tgData = await tgRes.json().catch(() => null);
      const status = tgData?.result?.status;

      if (!tgData?.ok || !MEMBER_STATUSES.has(status)) {
        return NextResponse.json({ error: "not_subscribed" }, { status: 409 });
      }
    }

    const { data: reward, error: claimError } = await supabase.rpc("claim_system_task", {
      p_user_id: userId,
      p_slug: slug,
    });
    if (claimError) throw claimError;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ reward, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
