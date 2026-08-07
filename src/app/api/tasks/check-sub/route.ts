import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const MEMBER_STATUSES = new Set(["member", "administrator", "creator"]);
const HOLD_MS = 24 * 60 * 60 * 1000;

async function isSubscribed(
  botToken: string,
  channelId: string,
  telegramId: number,
): Promise<boolean> {
  const tgRes = await fetch(
    `https://api.telegram.org/bot${botToken}/getChatMember` +
      `?chat_id=${encodeURIComponent(channelId)}&user_id=${telegramId}`,
  );
  const tgData = await tgRes.json().catch(() => null);
  return Boolean(tgData?.ok) && MEMBER_STATUSES.has(tgData?.result?.status);
}

/**
 * Two-phase now instead of one atomic verify+pay: a passing subscription
 * check only records verified_at (record_partner_task_verification) —
 * the reward isn't payable until 24h later, and only if a *second*
 * getChatMember check still passes then. Closes the subscribe -> claim ->
 * unsubscribe loophole the old immediate-payout flow had. See
 * 0044_partner_task_delayed_reward.sql for the schema/RPC side of this.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);
    const taskId = body?.taskId;
    if (typeof taskId !== "string" || !taskId) {
      return NextResponse.json({ error: "invalid_task" }, { status: 400 });
    }

    const botToken = process.env.TELEGRAM_BOT_TOKEN;
    if (!botToken) {
      return NextResponse.json({ error: "server_misconfigured" }, { status: 500 });
    }

    const supabase = supabaseServer();

    const [{ data: task, error: taskError }, { data: userRow, error: userError }] =
      await Promise.all([
        supabase.rpc("get_partner_task_channel", { p_task_id: taskId }),
        supabase.from("users").select("telegram_id").eq("id", userId).single(),
      ]);

    if (taskError || !task?.channel_id || !task.is_active) {
      return NextResponse.json({ error: "unknown_task" }, { status: 404 });
    }
    if (userError || !userRow) {
      return NextResponse.json({ error: "unknown_user" }, { status: 404 });
    }

    const { data: progress, error: progressError } = await supabase
      .from("user_partner_tasks")
      .select("verified_at, completed_at")
      .eq("user_id", userId)
      .eq("task_id", taskId)
      .maybeSingle();
    if (progressError) throw progressError;

    if (progress?.completed_at) {
      return NextResponse.json({ error: "already_claimed" }, { status: 409 });
    }

    // Already verified once — this click is trying to actually claim.
    if (progress?.verified_at) {
      const availableAt = new Date(progress.verified_at).getTime() + HOLD_MS;
      if (Date.now() < availableAt) {
        // Shouldn't normally happen — the client hides/disables the button
        // until available_at — but never trust that client-side alone.
        return NextResponse.json(
          { error: "too_early", available_at: new Date(availableAt).toISOString() },
          { status: 409 },
        );
      }

      const stillSubscribed = await isSubscribed(botToken, task.channel_id, userRow.telegram_id);
      if (!stillSubscribed) {
        // Unsubscribed sometime during the hold — wipe the pending
        // verification so a future resubscribe starts the 24h wait over,
        // instead of leaving a permanently-stuck row.
        await supabase.rpc("reset_partner_task_verification", {
          p_user_id: userId,
          p_task_id: taskId,
        });
        return NextResponse.json({ error: "not_subscribed" }, { status: 409 });
      }

      const { data: reward, error: claimError } = await supabase.rpc("claim_partner_task", {
        p_user_id: userId,
        p_task_id: taskId,
      });
      if (claimError) throw claimError;

      const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
        p_user_id: userId,
      });
      if (stateError) throw stateError;

      return NextResponse.json({ status: "claimed", reward, state });
    }

    // First time checking this task — just verify, don't pay yet.
    const subscribed = await isSubscribed(botToken, task.channel_id, userRow.telegram_id);
    if (!subscribed) {
      return NextResponse.json({ error: "not_subscribed" }, { status: 409 });
    }

    const { data: verification, error: verifyError } = await supabase.rpc(
      "record_partner_task_verification",
      { p_user_id: userId, p_task_id: taskId },
    );
    if (verifyError) throw verifyError;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({
      status: "pending",
      available_at: verification.available_at,
      state,
    });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
