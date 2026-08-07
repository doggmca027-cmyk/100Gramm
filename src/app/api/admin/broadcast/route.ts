import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";
export const maxDuration = 60;

// Users table is currently 1200+ rows and growing — sending the whole
// broadcast in one request (as this route used to) means one serverless
// invocation looping over every recipient with a live Telegram API call
// each. That comfortably blows past any Vercel function time limit long
// before it reaches the end of the list, so the platform kills the
// invocation mid-loop and the admin sees a bare failure — with an unknown
// number of messages already sent and no way to tell where it stopped.
// Fixed by turning this into one batch per request: the client
// (news-admin-section.tsx) calls this repeatedly with an increasing
// `offset`, we send BATCH_SIZE recipients and return where to resume, and
// the client keeps looping (updating a live sent/total count) until
// `done`. Each call comfortably finishes in a couple of seconds regardless
// of total recipient count or which Vercel plan/timeout applies.
const BATCH_SIZE = 20;

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
    const offset = Math.max(0, Number(form.get("offset") ?? 0) || 0);
    // Once the first batch has uploaded the photo once, every later batch
    // (and later sends within the same batch) reuses this file_id instead
    // of re-uploading the file — see the fileId handling below.
    let fileId = typeof form.get("fileId") === "string" ? (form.get("fileId") as string) : null;

    if (!title && !body) {
      return NextResponse.json({ error: "missing_content" }, { status: 400 });
    }

    const caption = title ? `<b>${escapeHtml(title)}</b>\n\n${escapeHtml(body)}` : escapeHtml(body);
    const maxLen = photoFile || fileId ? 1024 : 4096;
    if (caption.length > maxLen) {
      return NextResponse.json({ error: "content_too_long" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data: users, error, count } = await supabase
      .from("users")
      .select("telegram_id", { count: "exact" })
      .order("id")
      .range(offset, offset + BATCH_SIZE - 1);
    if (error) throw error;

    const total = count ?? 0;
    const chatIds = (users ?? []).map((u) => u.telegram_id as number);

    let sent = 0;
    let failed = 0;

    for (let i = 0; i < chatIds.length; i++) {
      const chatId = chatIds[i];
      try {
        if (photoFile || fileId) {
          if (fileId === null) {
            // Very first send of the whole broadcast: forward the real
            // file, then remember Telegram's file_id so every other
            // recipient (this batch and all later ones) reuses it instead
            // of re-uploading.
            const tgForm = new FormData();
            tgForm.append("chat_id", String(chatId));
            tgForm.append("caption", caption);
            tgForm.append("parse_mode", "HTML");
            tgForm.append("photo", photoFile as File, (photoFile as File).name);

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

    const nextOffset = offset + chatIds.length;
    return NextResponse.json({
      sent,
      failed,
      total,
      nextOffset,
      fileId,
      done: nextOffset >= total,
    });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
