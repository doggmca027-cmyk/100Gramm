import { NextRequest, NextResponse } from "next/server";
import {
  createSessionToken,
  SESSION_COOKIE_MAX_AGE,
  SESSION_COOKIE_NAME,
  validateTelegramInitData,
} from "@/lib/telegram-auth";
import { supabaseServer } from "@/lib/supabase-server";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  const botToken = process.env.TELEGRAM_BOT_TOKEN;
  if (!botToken) {
    return NextResponse.json({ error: "server_misconfigured" }, { status: 500 });
  }

  const body = await request.json().catch(() => null);
  const initData = body?.initData;
  if (typeof initData !== "string" || !initData) {
    return NextResponse.json({ error: "missing_init_data" }, { status: 400 });
  }

  let validated;
  try {
    validated = validateTelegramInitData(initData, botToken);
  } catch {
    return NextResponse.json({ error: "invalid_init_data" }, { status: 401 });
  }

  const supabase = supabaseServer();
  const { data: userId, error } = await supabase.rpc("bootstrap_user", {
    p_telegram_id: validated.user.id,
    p_username: validated.user.username ?? null,
    p_first_name: validated.user.first_name ?? null,
    p_ref_code: validated.startParam,
    p_photo_url: validated.user.photo_url ?? null,
  });

  if (error || !userId) {
    return NextResponse.json({ error: "bootstrap_failed" }, { status: 500 });
  }

  const token = await createSessionToken(userId);
  const response = NextResponse.json({ ok: true });
  response.cookies.set(SESSION_COOKIE_NAME, token, {
    httpOnly: true,
    secure: true,
    sameSite: "none",
    maxAge: SESSION_COOKIE_MAX_AGE,
    path: "/",
  });
  return response;
}
