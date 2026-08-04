import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const q = request.nextUrl.searchParams.get("q")?.trim() ?? "";
    if (!q) {
      return NextResponse.json([]);
    }

    const supabase = supabaseServer();
    let query = supabase
      .from("users")
      .select("id, telegram_id, username, first_name, is_ambassador")
      .limit(20);

    // Numeric query also matches telegram_id exactly; text always matches
    // username/first_name loosely.
    if (/^\d+$/.test(q)) {
      query = query.or(`telegram_id.eq.${q},username.ilike.%${q}%,first_name.ilike.%${q}%`);
    } else {
      query = query.or(`username.ilike.%${q}%,first_name.ilike.%${q}%`);
    }

    const { data, error } = await query;
    if (error) throw error;

    return NextResponse.json(data);
  } catch (error) {
    return apiErrorResponse(error);
  }
}
