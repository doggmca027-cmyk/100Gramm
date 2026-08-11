import "server-only";
import { supabaseServer } from "./supabase-server";
import { WEEKLY_PRIZE_POOL_TON } from "./gang-avatars";

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export type DistrictWarNotificationType = "district_war_start" | "district_war_end";

/**
 * Falls back to the bot this feature was specced against if the env var is
 * somehow unset — every other Telegram deep link in this app
 * (gangs-screen.tsx, squad-screen.tsx) already depends on
 * NEXT_PUBLIC_BOT_USERNAME being configured, so this is only ever a safety
 * net, not the expected path.
 */
function deepLink(): string {
  const botUsername = process.env.NEXT_PUBLIC_BOT_USERNAME;
  return `https://t.me/${botUsername ?? "Gram100Bot_bot"}/app`;
}

/**
 * Both messages are fixed copy with no interpolated user content, so —
 * unlike api/admin/broadcast/route.ts's admin-typed title/body — there's
 * nothing here that needs HTML-escaping.
 */
function messageFor(type: DistrictWarNotificationType): string {
  const link = deepLink();
  if (type === "district_war_start") {
    return (
      `⚔️ <b>ВНИМАНИЕ, БОЙЦЫ! ДО НАЧАЛА ВОЙНЫ ЗА РАЙОНЫ ОСТАЛОСЬ 30 МИНУТ!</b>\n\n` +
      `Скоро откроется 12-часовое окно битвы. Приготовьтесь завершать циклы, закупать Авиаудары и отстаивать территории своего Синдиката!\n\n` +
      `🏆 На кону недельный призовой фонд <b>${WEEKLY_PRIZE_POOL_TON} TON</b>!\n\n` +
      `👉 <a href="${link}">Открыть 100GRAM и подготовиться</a>`
    );
  }
  return (
    `🔥 <b>ФИНАЛЬНЫЕ 30 МИНУТ ВОЙНЫ ЗА РАЙОНЫ!</b>\n\n` +
    `Разрыв в очках минимален! Это решающий момент битвы за контроль над секторами города и позиции в ТОП-15 Лидерборда.\n\n` +
    `🚀 Включайте <b>Авиаудары 3X</b> и активируйте <b>Инженерный Щит</b>, чтобы вырвать победу в последние минуты!\n\n` +
    `👉 <a href="${link}">Срочно войти в бой!</a>`
  );
}

export interface DistrictWarNotifyResult {
  notification_type: DistrictWarNotificationType | null;
  claimed: boolean;
  sent: number;
  failed: number;
  total: number;
  /** Set instead of actually sending when there's nothing to do — no bot token, no reminder due right now, or today's slot for this type was already claimed by an earlier invocation. */
  skipped?: "server_misconfigured" | "not_due" | "already_sent";
}

/**
 * Called by the cron route (see api/cron/district-war-notifications) —
 * everything about "is a reminder due, who gets it, has it already been
 * sent today" is decided by run_district_war_notifications()
 * (0073_district_war_notifications.sql); this function's only job is the
 * actual Telegram Bot API calls plus writing back what happened.
 *
 * Reuses the exact chat_id-is-telegram_id + sequential-with-40ms-sleep
 * send pattern from api/admin/broadcast/route.ts / lib/notify-ambassadors-
 * combo.ts (Telegram's ~30msg/s rate limit).
 */
export async function runDistrictWarNotifications(): Promise<DistrictWarNotifyResult> {
  const botToken = process.env.TELEGRAM_BOT_TOKEN;
  if (!botToken) {
    return { notification_type: null, claimed: false, sent: 0, failed: 0, total: 0, skipped: "server_misconfigured" };
  }

  const supabase = supabaseServer();
  const { data, error } = await supabase.rpc("run_district_war_notifications");
  if (error) throw error;

  const notificationType = (data?.notification_type ?? null) as DistrictWarNotificationType | null;
  if (!notificationType) {
    return { notification_type: null, claimed: false, sent: 0, failed: 0, total: 0, skipped: "not_due" };
  }
  if (!data.claimed) {
    return { notification_type: notificationType, claimed: false, sent: 0, failed: 0, total: 0, skipped: "already_sent" };
  }

  const chatIds = (data.audience as number[]) ?? [];
  const text = messageFor(notificationType);

  let sent = 0;
  let failed = 0;
  const blockedTelegramIds: number[] = [];

  for (let i = 0; i < chatIds.length; i++) {
    try {
      const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: chatIds[i],
          text,
          parse_mode: "HTML",
          disable_web_page_preview: true,
        }),
      });
      const body = await res.json();
      if (!body.ok) {
        // Telegram answers 403 "Forbidden: bot was blocked by the user"
        // (or the near-identical "user is deactivated") when a DM to this
        // chat can never succeed again — recorded so future notifications
        // stop wasting a request on them.
        if (res.status === 403 || /blocked|deactivated/i.test(body.description ?? "")) {
          blockedTelegramIds.push(chatIds[i]);
        }
        throw new Error(body.description ?? "sendMessage failed");
      }
      sent++;
    } catch (err) {
      console.error(`District war notify (${notificationType}) failed for chat ${chatIds[i]}:`, err);
      failed++;
    }

    if (i < chatIds.length - 1) await sleep(40);
  }

  await supabase
    .from("notification_logs")
    .update({ sent_count: sent, failed_count: failed })
    .eq("notification_type", notificationType)
    .eq("reference_date", data.reference_date);

  if (blockedTelegramIds.length > 0) {
    await supabase.from("users").update({ telegram_blocked: true }).in("telegram_id", blockedTelegramIds);
  }

  return { notification_type: notificationType, claimed: true, sent, failed, total: chatIds.length };
}
