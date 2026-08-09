import { NextRequest, NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { SIGNATURE_HEADER, verifySignature } from "@/lib/partner-webhook";

export const runtime = "nodejs";

/**
 * The reward-granting webhook a partner's backend calls once a target
 * action we sent one of our users out to do in *their* app is done —
 * "OUTGOING" from our task's point of view, see the migration header
 * (0055_partner_cross_app_tasks.sql) for the full two-direction picture.
 *
 * No session/CSRF here on purpose — this is a server-to-server call from
 * the partner's backend, which has no cookies of ours. The only auth is
 * the HMAC signature over the raw body, checked against the partner_apps
 * row `slug` names — never trust anything else in the request. `token`
 * alone (an unguessable uuid minted by create_partner_task_click) is the
 * actual capability; resolve_partner_task_click never trusts a client-
 * supplied user/task id.
 */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ slug: string }> },
) {
  try {
    const { slug } = await params;
    const rawBody = await request.text();

    const supabase = supabaseServer();
    const { data: partner, error: partnerError } = await supabase
      .from("partner_apps")
      .select("id, secret, is_active")
      .eq("slug", slug)
      .maybeSingle();
    if (partnerError) throw partnerError;
    if (!partner || !partner.is_active) {
      return NextResponse.json({ error: "unknown_partner" }, { status: 404 });
    }

    const signature = request.headers.get(SIGNATURE_HEADER);
    if (!verifySignature(partner.secret, rawBody, signature)) {
      return NextResponse.json({ error: "invalid_signature" }, { status: 401 });
    }

    const body = JSON.parse(rawBody) as { token?: unknown; success?: unknown };
    const token = typeof body.token === "string" ? body.token : null;
    const success = body.success === true;
    const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!token || !UUID_RE.test(token)) {
      return NextResponse.json({ error: "missing_token" }, { status: 400 });
    }

    const { data: result, error: resolveError } = await supabase.rpc("resolve_partner_task_click", {
      p_token: token,
      p_success: success,
      p_partner_app_id: partner.id,
    });
    if (resolveError) throw resolveError;

    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
