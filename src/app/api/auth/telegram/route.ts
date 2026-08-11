import { NextRequest, NextResponse } from "next/server";
import {
  createSessionToken,
  CSRF_COOKIE_NAME,
  generateCsrfToken,
  SESSION_COOKIE_MAX_AGE,
  SESSION_COOKIE_NAME,
  validateTelegramInitData,
} from "@/lib/telegram-auth";
import { supabaseServer } from "@/lib/supabase-server";
import { notifyPartnerCallback, parseInboundStartParam } from "@/lib/partner-webhook";

export const runtime = "nodejs";

/**
 * The "OUTGOING" half of cross-app task verification (see
 * 0055_partner_cross_app_tasks.sql's header): a partner sends us a user
 * via ?startapp=p100_<slug>_<their token>. The first time that user's
 * session bootstraps, we record it and (best-effort) tell the partner
 * {token, success:true} — "opened our app" is the target action for a v1
 * that has to work without the partner integrating anything beyond reading
 * our postback.
 *
 * Only the *recording* (a couple of cheap DB round trips) is awaited here —
 * the actual outbound HTTP call to the partner is deliberately NOT awaited
 * by the caller (see the `void notifyPartnerCallback(...)` below), so a
 * slow or dead partner endpoint can never add latency to a real user's
 * login, only to whether the partner ever finds out. This is a
 * genuine best-effort notification, not a guaranteed one: if the hosting
 * platform tears the process down immediately after the response is sent
 * (some serverless environments do), the in-flight fetch may not finish.
 * Acceptable here since this only affects a *partner's* bookkeeping, never
 * our own user's flow.
 */
async function recordInboundPartnerClick(
  startParam: string | null,
  userId: string,
): Promise<{ partnerAppId: string; url: string; secret: string; token: string } | null> {
  if (!startParam) return null;
  const parsed = parseInboundStartParam(startParam);
  if (!parsed) return null;

  try {
    const supabase = supabaseServer();
    const { data: partner, error: partnerError } = await supabase
      .from("partner_apps")
      .select("id, secret, outgoing_callback_url, is_active")
      .eq("slug", parsed.partnerSlug)
      .maybeSingle();
    if (partnerError || !partner || !partner.is_active || !partner.outgoing_callback_url) return null;

    const { error: insertError } = await supabase
      .from("partner_inbound_clicks")
      .insert({ partner_app_id: partner.id, partner_token: parsed.partnerToken, user_id: userId })
      .select()
      .single();

    if (insertError) {
      // 23505 = unique_violation -> we've already notified for this exact
      // (partner, token) pair before, on an earlier open. Anything else is
      // a real failure, but still not one that should touch the response.
      return null;
    }

    return {
      partnerAppId: partner.id,
      url: partner.outgoing_callback_url,
      secret: partner.secret,
      token: parsed.partnerToken,
    };
  } catch (err) {
    console.error("recordInboundPartnerClick failed:", err);
    return null;
  }
}

/**
 * The other consumer of ?startapp=... besides the referral code (bare
 * digits, handled inside bootstrap_user) and the partner-app prefix (see
 * recordInboundPartnerClick above): a gang's "Пригласить" link encodes
 * `gang_<uuid>`. bootstrap_user's own ref-code parsing only matches
 * `^[0-9]+$`, so this never collides with a referral code, and it doesn't
 * start with the partner prefix either — safe to check unconditionally.
 *
 * Runs on every launch (this whole route does, not just first-ever login),
 * so re-opening the same invite link after already joining a gang, or
 * after the gang is full/gone, just fails with a known RPC error that's
 * silently swallowed here — never allowed to block login, same posture as
 * the partner-click notification below.
 *
 * join_gang (0078_gang_closed_paid_description.sql) refuses anything that
 * would need leader approval (gang_closed) or move money
 * (gang_requires_payment) — deliberately, since this whole path runs with
 * no user interaction at all, so it can never silently charge someone or
 * file something on their behalf without them tapping anything. The one
 * exception: gang_closed specifically falls back to request_join_gang,
 * which is safe to do silently too — no balance is ever touched by filing
 * an application, only by a leader later approving it.
 */
const GANG_START_PARAM_PREFIX = "gang_";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function tryJoinGangFromStartParam(startParam: string | null, userId: string): Promise<void> {
  if (!startParam || !startParam.startsWith(GANG_START_PARAM_PREFIX)) return;
  const gangId = startParam.slice(GANG_START_PARAM_PREFIX.length);
  if (!UUID_RE.test(gangId)) return;

  try {
    const { error } = await supabaseServer().rpc("join_gang", { p_user_id: userId, p_gang_id: gangId });
    // Known failure modes (already_in_gang, gang_not_found, gang_full,
    // gang_requires_payment) and anything else are all equally fine to
    // ignore here — the user just lands in the app normally, same as
    // opening it without a start param. gang_closed alone gets one retry
    // as a (money-free) join request instead of being swallowed outright.
    if (error?.message?.includes("gang_closed")) {
      await supabaseServer().rpc("request_join_gang", { p_user_id: userId, p_gang_id: gangId });
    }
  } catch (err) {
    console.error("tryJoinGangFromStartParam failed:", err);
  }
}

/** Fires the outbound webhook and stamps notified_at once it succeeds — never awaited by the caller. */
async function fireInboundPartnerNotification(pending: {
  partnerAppId: string;
  url: string;
  secret: string;
  token: string;
}): Promise<void> {
  await notifyPartnerCallback(pending.url, pending.secret, { token: pending.token, success: true });
  await supabaseServer()
    .from("partner_inbound_clicks")
    .update({ notified_at: new Date().toISOString() })
    .eq("partner_app_id", pending.partnerAppId)
    .eq("partner_token", pending.token);
}

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

  await tryJoinGangFromStartParam(validated.startParam, userId);

  const pendingPartnerNotify = await recordInboundPartnerClick(validated.startParam, userId);
  if (pendingPartnerNotify) {
    // Deliberately not awaited — see recordInboundPartnerClick's doc
    // comment. .catch is just to avoid an unhandled-rejection warning;
    // notifyPartnerCallback already swallows its own errors internally.
    void fireInboundPartnerNotification(pendingPartnerNotify).catch((err) =>
      console.error("fireInboundPartnerNotification failed:", err),
    );
  }

  const token = await createSessionToken(userId);
  const csrfToken = generateCsrfToken();
  const response = NextResponse.json({ ok: true });
  response.cookies.set(SESSION_COOKIE_NAME, token, {
    httpOnly: true,
    secure: true,
    sameSite: "none",
    maxAge: SESSION_COOKIE_MAX_AGE,
    path: "/",
  });
  // Not httpOnly on purpose — api-client.ts reads this to echo it back as
  // the X-CSRF-Token header on every mutating request. See assertCsrfToken.
  response.cookies.set(CSRF_COOKIE_NAME, csrfToken, {
    httpOnly: false,
    secure: true,
    sameSite: "none",
    maxAge: SESSION_COOKIE_MAX_AGE,
    path: "/",
  });
  return response;
}
