import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";
import { generatePartnerSecret } from "@/lib/partner-webhook";

export const runtime = "nodejs";

/** Toggle is_active, update outgoing_callback_url, and/or rotate the shared secret. */
export async function PATCH(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    await requireAdminUserId(request);
    const { id } = await params;
    const body = await request.json().catch(() => null);

    const update: Record<string, unknown> = {};
    if (typeof body?.isActive === "boolean") update.is_active = body.isActive;
    if (typeof body?.outgoingCallbackUrl === "string") {
      update.outgoing_callback_url = body.outgoingCallbackUrl.trim() || null;
    }
    if (body?.rotateSecret === true) {
      update.secret = generatePartnerSecret();
    }

    if (Object.keys(update).length === 0) {
      return NextResponse.json({ error: "nothing_to_update" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data, error } = await supabase
      .from("partner_apps")
      .update(update)
      .eq("id", id)
      .select()
      .single();
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
