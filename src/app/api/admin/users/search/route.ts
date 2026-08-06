import { NextRequest, NextResponse } from "next/server";
import { requireAdminUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    await requireAdminUserId(request);
    const rawQ = request.nextUrl.searchParams.get("q")?.trim() ?? "";
    // PostgREST's .or() takes a raw filter string — "," separates
    // conditions and "()" groups them, so those characters are
    // syntax-significant there. Left unescaped, a crafted q could inject
    // extra filter clauses (e.g. widen the match, reference other
    // columns) into a query that otherwise only takes admin-supplied
    // input, not just narrow the intended ilike search. Stripping them is
    // enough — nothing about a legitimate username/telegram-id search
    // legitimately needs those characters.
    const q = rawQ.replace(/[,()]/g, "");
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
