import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const MEMBER_STATUSES = new Set(["member", "administrator", "creator"]);
const HOLD_MS = 24 * 60 * 60 * 1000;

/**
 * Telegram's getChatMember only recognizes a username-based chat_id when
 * it's prefixed with "@" — a bare "GRam100_NEWS" comes back "chat not
 * found" even though the channel exists. target_value is stored bare
 * (same value the frontend uses to build the t.me/ link, see
 * targetUrl() in system-tasks-section.tsx), so it's normalized here
 * rather than forcing whoever fills in the admin data to remember to type
 * "@". Already-prefixed usernames and numeric chat ids (private/super
 * groups look like "-100...") are passed through unchanged.
 */
function toChatId(targetValue: string): string {
  return /^[@-]/.test(targetValue) || /^\d+$/.test(targetValue) ? targetValue : `@${targetValue}`;
}

async function isSubscribed(
  botToken: string,
  targetValue: string,
  telegramId: number,
): Promise<boolean> {
  const tgRes = await fetch(
    `https://api.telegram.org/bot${botToken}/getChatMember` +
      `?chat_id=${encodeURIComponent(toChatId(targetValue))}&user_id=${telegramId}`,
  );
  const tgData = await tgRes.json().catch(() => null);
  return Boolean(tgData?.ok) && MEMBER_STATUSES.has(tgData?.result?.status);
}

/**
 * Claims a system task's reward (see 0028_system_tasks.sql — items + XP,
 * never GRAM). Referral/gameplay tasks (and the post_view self-report
 * social task) are verified entirely inside claim_system_task and pay out
 * on the spot, same as always.
 *
 * channel_sub/chat_join social tasks are now two-phase (0045_system_task_delayed_reward.sql):
 * a passing getChatMember check only records verified_at
 * (record_system_task_verification) — the reward isn't payable until 24h
 * later, and only if a *second* getChatMember check still passes then.
 * Closes the subscribe -> claim -> unsubscribe loophole the old
 * check-then-claim-in-one-request flow had. Same pattern as
 * /api/tasks/check-sub for partner_tasks.
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
      .select("id, category, target_type, target_value, is_active")
      .eq("slug", slug)
      .maybeSingle();
    if (taskError) throw taskError;
    if (!task || !task.is_active) {
      return NextResponse.json({ error: "unknown_task" }, { status: 404 });
    }

    const isDelayedSocial =
      task.category === "social" && (task.target_type === "channel_sub" || task.target_type === "chat_join");

    if (isDelayedSocial) {
      if (!task.target_value) {
        return NextResponse.json({ error: "task_not_configured" }, { status: 409 });
      }

      const botToken = process.env.TELEGRAM_BOT_TOKEN;
      if (!botToken) {
        return NextResponse.json({ error: "server_misconfigured" }, { status: 500 });
      }

      const [{ data: userRow, error: userError }, { data: seasonId, error: seasonError }] =
        await Promise.all([
          supabase.from("users").select("telegram_id").eq("id", userId).single(),
          supabase.rpc("active_season_id"),
        ]);
      if (userError || !userRow) {
        return NextResponse.json({ error: "unknown_user" }, { status: 404 });
      }
      if (seasonError) throw seasonError;
      if (!seasonId) {
        return NextResponse.json({ error: "no_active_season" }, { status: 409 });
      }

      const { data: progress, error: progressError } = await supabase
        .from("user_completed_tasks")
        .select("verified_at, completed_at")
        .eq("user_id", userId)
        .eq("season_id", seasonId)
        .eq("task_id", task.id)
        .maybeSingle();
      if (progressError) throw progressError;

      if (progress?.completed_at) {
        return NextResponse.json({ error: "already_claimed" }, { status: 409 });
      }

      // Already verified once — this click is trying to actually claim.
      if (progress?.verified_at) {
        const availableAt = new Date(progress.verified_at).getTime() + HOLD_MS;
        if (Date.now() < availableAt) {
          // Shouldn't normally happen — the client disables the button
          // until available_at — but never trust that client-side alone.
          return NextResponse.json(
            { error: "too_early", available_at: new Date(availableAt).toISOString() },
            { status: 409 },
          );
        }

        const stillSubscribed = await isSubscribed(botToken, task.target_value, userRow.telegram_id);
        if (!stillSubscribed) {
          // Unsubscribed sometime during the hold — wipe the pending
          // verification so a future resubscribe starts the 24h wait over.
          await supabase.rpc("reset_system_task_verification", {
            p_user_id: userId,
            p_task_id: task.id,
          });
          return NextResponse.json({ error: "not_subscribed" }, { status: 409 });
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

        return NextResponse.json({ status: "claimed", reward, state });
      }

      // First time checking this task — just verify, don't pay yet.
      const subscribed = await isSubscribed(botToken, task.target_value, userRow.telegram_id);
      if (!subscribed) {
        return NextResponse.json({ error: "not_subscribed" }, { status: 409 });
      }

      const { data: verification, error: verifyError } = await supabase.rpc(
        "record_system_task_verification",
        { p_user_id: userId, p_task_id: task.id },
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
    }

    // referral / gameplay / post_view — unchanged, instant claim.
    const { data: reward, error: claimError } = await supabase.rpc("claim_system_task", {
      p_user_id: userId,
      p_slug: slug,
    });
    if (claimError) throw claimError;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ status: "claimed", reward, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
