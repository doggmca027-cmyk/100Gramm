import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const MEMBER_STATUSES = new Set(["member", "administrator", "creator"]);

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

    const tgRes = await fetch(
      `https://api.telegram.org/bot${botToken}/getChatMember` +
        `?chat_id=${encodeURIComponent(task.channel_id)}&user_id=${userRow.telegram_id}`,
    );
    const tgData = await tgRes.json().catch(() => null);
    const status = tgData?.result?.status;

    if (!tgData?.ok || !MEMBER_STATUSES.has(status)) {
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

    return NextResponse.json({ reward, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
