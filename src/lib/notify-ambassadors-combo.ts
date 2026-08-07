import "server-only";
import { supabaseServer } from "./supabase-server";
import { loadAdminDailyCombo } from "./daily-combo";

const TIER_EMOJI = ["1️⃣", "2️⃣", "3️⃣", "4️⃣"];

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface NotifyAmbassadorsResult {
  sent: number;
  failed: number;
  total: number;
  /** Set instead of sending anything when there's nothing to do yet (no bot token / no active season). */
  skipped?: "server_misconfigured" | "no_active_season";
}

/**
 * DMs every user flagged users.is_ambassador with today's daily-combo
 * *secret* answer — a deliberate ambassador perk. The daily combo is
 * normally a Mastermind-style guessing game (submit_daily_combo_guess,
 * see 0017/0027_combo_item_drops.sql): the 4-tier order is hidden from
 * everyone until they guess it correctly. Ambassadors get it handed to
 * them directly instead, so they can win the combo item drop every day
 * without guessing.
 *
 * Called from wherever today's secret tiers can come to exist or change:
 * - the daily cron backstop (src/app/api/cron/notify-ambassadors-combo),
 *   for the ordinary once-a-day reset,
 * - the admin "regenerate" and "set tiers manually" routes, since either
 *   one changes the correct answer for the rest of the day — anyone
 *   notified before that point would otherwise have been sent a now-wrong
 *   answer.
 *
 * Reuses the exact chat_id-is-telegram_id + sequential-with-40ms-sleep
 * send pattern from api/admin/broadcast/route.ts (Telegram's ~30msg/s
 * rate limit) — ambassador lists are expected to be far smaller than the
 * full user base, but there's no reason to risk hitting the limit anyway.
 */
export async function notifyAmbassadorsOfDailyCombo(): Promise<NotifyAmbassadorsResult> {
  const botToken = process.env.TELEGRAM_BOT_TOKEN;
  if (!botToken) return { sent: 0, failed: 0, total: 0, skipped: "server_misconfigured" };

  const supabase = supabaseServer();

  const { data: seasonId, error: seasonError } = await supabase.rpc("active_season_id");
  if (seasonError) throw seasonError;
  if (!seasonId) return { sent: 0, failed: 0, total: 0, skipped: "no_active_season" };

  const combo = await loadAdminDailyCombo(seasonId);

  const { data: ambassadors, error: ambassadorsError } = await supabase
    .from("users")
    .select("telegram_id")
    .eq("is_ambassador", true);
  if (ambassadorsError) throw ambassadorsError;

  const chatIds = (ambassadors ?? []).map((u) => u.telegram_id as number);
  if (chatIds.length === 0) return { sent: 0, failed: 0, total: 0 };

  const order = combo.tiers
    .map((t, i) => `${TIER_EMOJI[i] ?? `${i + 1}.`} ${escapeHtml(t.name)}`)
    .join("\n");
  const text =
    `🎯 <b>Комбо дня — привилегия амбассадора</b>\n\n` +
    `Сегодняшний секретный порядок:\n${order}\n\n` +
    `Введи тиры именно в этом порядке в разделе «Игры», чтобы гарантированно выиграть.`;

  let sent = 0;
  let failed = 0;
  for (let i = 0; i < chatIds.length; i++) {
    try {
      const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: chatIds[i], text, parse_mode: "HTML" }),
      });
      const data = await res.json();
      if (!data.ok) throw new Error(data.description ?? "sendMessage failed");
      sent++;
    } catch (err) {
      console.error(`Ambassador combo notify failed for chat ${chatIds[i]}:`, err);
      failed++;
    }

    if (i < chatIds.length - 1) await sleep(40);
  }

  return { sent, failed, total: chatIds.length };
}
