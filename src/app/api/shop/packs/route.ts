import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    // Gated behind the same session as the rest of the app (not because the
    // catalog is sensitive, but nothing here is reachable without it anyway).
    await requireUserId(request);

    const supabase = supabaseServer();
    const { data, error } = await supabase
      .from("gram_packs")
      .select("id, title, gram_amount, price_ton")
      .eq("is_active", true)
      .order("sort_order", { ascending: true });

    if (error) throw error;

    return NextResponse.json({ packs: data });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
