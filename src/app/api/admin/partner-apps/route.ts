import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { generatePartnerSecret } from "@/lib/partner-webhook";

export const runtime = "nodejs";

const SLUG_RE = /^[a-z0-9-]{2,32}$/;

export async function GET(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const supabase = supabaseServer();

    const { data, error } = await supabase
      .from("partner_apps")
      .select("id, slug, name, secret, outgoing_callback_url, is_active, created_at")
      .order("created_at", { ascending: false });
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const body = await request.json().catch(() => null);

    const slug = typeof body?.slug === "string" ? body.slug.trim().toLowerCase() : "";
    const name = typeof body?.name === "string" ? body.name.trim() : "";
    const outgoingCallbackUrl =
      typeof body?.outgoingCallbackUrl === "string" && body.outgoingCallbackUrl.trim()
        ? body.outgoingCallbackUrl.trim()
        : null;

    if (!SLUG_RE.test(slug)) {
      return NextResponse.json({ error: "invalid_slug" }, { status: 400 });
    }
    if (!name) {
      return NextResponse.json({ error: "missing_name" }, { status: 400 });
    }

    const supabase = supabaseServer();
    // Random secret, never accepted from the client -- an admin who wants
    // one they typed themselves (e.g. matching what they already gave the
    // partner) can still overwrite it via the PATCH route below.
    const secret = generatePartnerSecret();

    const { data, error } = await supabase
      .from("partner_apps")
      .insert({ slug, name, secret, outgoing_callback_url: outgoingCallbackUrl })
      .select()
      .single();
    if (error) {
      if (error.code === "23505") {
        return NextResponse.json({ error: "duplicate_slug" }, { status: 409 });
      }
      throw error;
    }

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
