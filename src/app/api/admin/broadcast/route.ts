import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";
export const maxDuration = 60;

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function POST(request: NextRequest) {
  try {
    await requireAdminUserId(request);

    const botToken = process.env.TELEGRAM_BOT_TOKEN;
    if (!botToken) {
      return NextResponse.json({ error: "server_misconfigured" }, { status: 500 });
    }

    const form = await request.formData();
    const title = String(form.get("title") ?? "").trim();
    const body = String(form.get("body") ?? "").trim();
    const photo = form.get("photo");
    const photoFile = photo instanceof File && photo.size > 0 ? photo : null;

    if (!title && !body) {
      return NextResponse.json({ error: "missing_content" }, { status: 400 });
    }

    const caption = title ? `<b>${escapeHtml(title)}</b>\n\n${escapeHtml(body)}` : escapeHtml(body);
    const maxLen = photoFile ? 1024 : 4096;
    if (caption.length > maxLen) {
      return NextResponse.json({ error: "content_too_long" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data: users, error } = await supabase.from("users").select("telegram_id");
    if (error) throw error;

    const chatIds = (users ?? []).map((u) => u.telegram_id as number);
    if (chatIds.length === 0) {
      return NextResponse.json({ sent: 0, failed: 0, total: 0 });
    }

    let sent = 0;
    let failed = 0;
    let fileId: string | null = null;

    for (let i = 0; i < chatIds.length; i++) {
      const chatId = chatIds[i];
      try {
        if (photoFile) {
          if (fileId === null) {
            // First send: forward the real file, then remember Telegram's
            // file_id so every other recipient reuses it (no re-upload).
            const tgForm = new FormData();
            tgForm.append("chat_id", String(chatId));
            tgForm.append("caption", caption);
            tgForm.append("parse_mode", "HTML");
            tgForm.append("photo", photoFile, photoFile.name);

            const res = await fetch(`https://api.telegram.org/bot${botToken}/sendPhoto`, {
              method: "POST",
              body: tgForm,
            });
            const data = await res.json();
            if (!data.ok) throw new Error(data.description ?? "sendPhoto failed");
            const sizes = data.result?.photo;
            fileId = sizes?.[sizes.length - 1]?.file_id ?? null;
          } else {
            const res = await fetch(`https://api.telegram.org/bot${botToken}/sendPhoto`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                chat_id: chatId,
                photo: fileId,
                caption,
                parse_mode: "HTML",
              }),
            });
            const data = await res.json();
            if (!data.ok) throw new Error(data.description ?? "sendPhoto failed");
          }
        } else {
          const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ chat_id: chatId, text: caption, parse_mode: "HTML" }),
          });
          const data = await res.json();
          if (!data.ok) throw new Error(data.description ?? "sendMessage failed");
        }
        sent++;
      } catch {
        failed++;
      }

      // Stay comfortably under Telegram's ~30 msg/sec broadcast rate limit.
      if (i < chatIds.length - 1) await sleep(40);
    }

    return NextResponse.json({ sent, failed, total: chatIds.length });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
