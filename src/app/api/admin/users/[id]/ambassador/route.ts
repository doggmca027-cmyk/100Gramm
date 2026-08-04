import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function PATCH(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    await requireAdminUserId(request);
    const { id } = await params;
    const body = await request.json().catch(() => null);
    const isAmbassador = Boolean(body?.isAmbassador);

    const supabase = supabaseServer();
    const { error } = await supabase
      .from("users")
      .update({ is_ambassador: isAmbassador })
      .eq("id", id);
    if (error) throw error;

    return NextResponse.json({ ok: true });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
