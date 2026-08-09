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
