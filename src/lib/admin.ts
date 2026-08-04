/**
 * Admin allowlist by Telegram id. Deliberately NEXT_PUBLIC_ (readable
 * client-side too) so the UI can hide the ⚙️ button for non-admins — that's
 * only a display convenience. The real gate is server-side: every admin API
 * route re-checks this list itself against the caller's own telegram_id
 * resolved from their session, never trusting anything the client sends.
 */
function adminIds(): string[] {
  return (process.env.NEXT_PUBLIC_ADMIN_TELEGRAM_IDS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

export function isAdminTelegramId(telegramId: string | null | undefined): boolean {
  return !!telegramId && adminIds().includes(telegramId);
}

/** Accepts a t.me link, @username, or bare username; returns the bare username. */
export function parseChannelUsername(input: string): string | null {
  const trimmed = input.trim();
  const match = trimmed.match(
    /^(?:https?:\/\/)?(?:t\.me|telegram\.me)\/@?([a-zA-Z0-9_]{5,32})\/?$|^@?([a-zA-Z0-9_]{5,32})$/,
  );
  if (!match) return null;
  return match[1] ?? match[2] ?? null;
}
