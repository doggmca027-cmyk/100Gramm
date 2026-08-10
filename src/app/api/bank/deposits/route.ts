import { NextRequest, NextResponse } from "next/server";
import { requireUserId } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase-server";
import { apiErrorResponse } from "@/lib/api-error";

export const runtime = "nodejs";

const VALID_PLAN_DAYS = new Set([7, 14, 30]);

/**
 * Opens a Bank deposit. The client-side src/lib/bank-plans.ts min-amount
 * check exists purely to grey out the button early — create_bank_deposit
 * (0056_bank_staking.sql) re-validates the plan's minimum, the season, and
 * the balance itself, and is the only thing that actually moves GRAM.
 */
export async function POST(request: NextRequest) {
  try {
    const userId = await requireUserId(request);
    const body = await request.json().catch(() => null);

    const planDays = Number(body?.planDays);
    const amount = Number(body?.amount);

    if (!VALID_PLAN_DAYS.has(planDays)) {
      return NextResponse.json({ error: "invalid_plan" }, { status: 400 });
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      return NextResponse.json({ error: "amount_too_low" }, { status: 400 });
    }

    const supabase = supabaseServer();
    const { data: result, error } = await supabase.rpc("create_bank_deposit", {
      p_user_id: userId,
      p_plan_days: planDays,
      p_amount: amount,
    });
    if (error) throw error;

    const { data: state, error: stateError } = await supabase.rpc("get_player_state", {
      p_user_id: userId,
    });
    if (stateError) throw stateError;

    return NextResponse.json({ result, state });
  } catch (error) {
    return apiErrorResponse(error);
  }
}
