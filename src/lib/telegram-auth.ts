import "server-only";
import { createHmac, randomBytes } from "node:crypto";
import { SignJWT, jwtVerify } from "jose";

export const SESSION_COOKIE_NAME = "session";
// Double-submit CSRF cookie, issued alongside the session cookie on every
// bootstrap. Deliberately *not* httpOnly — the client needs to read it and
// echo it back as the X-CSRF-Token header (see api-client.ts). Its security
// doesn't depend on secrecy from the legitimate frontend; it depends on a
// cross-origin attacker being unable to read *this app's* cookies (browsers
// never expose another origin's document.cookie to script) or to set custom
// headers on a plain cross-site form submission. See assertCsrfToken in
// session.ts for where it's checked.
export const CSRF_COOKIE_NAME = "csrf_token";
const SESSION_TTL_SECONDS = 60 * 60 * 24 * 30; // 30 days — covers a full season
const MAX_INIT_DATA_AGE_SECONDS = 60 * 60 * 24; // 24h, generous for a Mini App that stays open

export interface TelegramInitDataUser {
  id: number;
  username?: string;
  first_name?: string;
  photo_url?: string;
}

export interface ValidatedInitData {
  user: TelegramInitDataUser;
  startParam: string | null;
}

/**
 * Sentinel hash used only by src/components/app-bootstrap.tsx's mockTelegramEnv
 * fallback (plain-browser dev preview, outside a real Telegram client — that
 * mock can't produce a real HMAC since it doesn't know the bot token). Matching
 * this exact value skips signature verification, but only when NODE_ENV isn't
 * "production" — `next build`/Vercel always set it to "production", so this
 * branch is dead code in any deployed environment regardless of other env vars.
 */
const DEV_MOCK_HASH = "dev-mock-hash";

/**
 * Validates a Telegram WebApp `initData` string per the official algorithm:
 * https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app
 *
 * secret_key = HMAC_SHA256(key="WebAppData", data=bot_token)
 * hash       = hex(HMAC_SHA256(key=secret_key, data=data_check_string))
 */
export function validateTelegramInitData(
  initDataRaw: string,
  botToken: string,
): ValidatedInitData {
  const params = new URLSearchParams(initDataRaw);
  const receivedHash = params.get("hash");
  if (!receivedHash) {
    throw new Error("init_data_missing_hash");
  }

  if (process.env.NODE_ENV !== "production" && receivedHash === DEV_MOCK_HASH) {
    const rawUser = params.get("user");
    if (!rawUser) throw new Error("init_data_missing_user");
    return {
      user: JSON.parse(rawUser) as TelegramInitDataUser,
      startParam: params.get("start_param"),
    };
  }

  params.delete("hash");

  const dataCheckString = [...params.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");

  const secretKey = createHmac("sha256", "WebAppData").update(botToken).digest();
  const computedHash = createHmac("sha256", secretKey).update(dataCheckString).digest("hex");

  if (computedHash !== receivedHash) {
    throw new Error("init_data_invalid_hash");
  }

  const authDate = Number(params.get("auth_date"));
  if (!authDate || Date.now() / 1000 - authDate > MAX_INIT_DATA_AGE_SECONDS) {
    throw new Error("init_data_expired");
  }

  const rawUser = params.get("user");
  if (!rawUser) {
    throw new Error("init_data_missing_user");
  }

  const parsedUser = JSON.parse(rawUser) as TelegramInitDataUser;
  if (typeof parsedUser.id !== "number") {
    throw new Error("init_data_invalid_user");
  }

  return {
    user: parsedUser,
    startParam: params.get("start_param"),
  };
}

function sessionSecretKey() {
  const secret = process.env.SESSION_SECRET;
  if (!secret) {
    throw new Error("Missing SESSION_SECRET env var");
  }
  return new TextEncoder().encode(secret);
}

export async function createSessionToken(userId: string): Promise<string> {
  return new SignJWT({ sub: userId })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(`${SESSION_TTL_SECONDS}s`)
    .sign(sessionSecretKey());
}

export async function verifySessionToken(token: string): Promise<string | null> {
  try {
    const { payload } = await jwtVerify(token, sessionSecretKey());
    return typeof payload.sub === "string" ? payload.sub : null;
  } catch {
    return null;
  }
}

export const SESSION_COOKIE_MAX_AGE = SESSION_TTL_SECONDS;

export function generateCsrfToken(): string {
  return randomBytes(24).toString("hex");
}
