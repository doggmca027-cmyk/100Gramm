import { supabaseServer } from "./supabase-server";

/** Shapes today's combo row + the tier catalogue into what the admin UI needs. */
export async function loadAdminDailyCombo(seasonId: string) {
  const supabase = supabaseServer();

  const { data: combo, error: comboError } = await supabase.rpc("ensure_daily_combo", {
    p_season_id: seasonId,
  });
  if (comboError) throw comboError;

  const { data: allTiers, error: tiersError } = await supabase
    .from("product_templates")
    .select("tier, name")
    .eq("season_id", seasonId)
    .order("tier");
  if (tiersError) throw tiersError;

  const nameByTier = new Map((allTiers ?? []).map((t) => [t.tier, t.name as string]));

  return {
    id: combo.id as string,
    combo_date: combo.combo_date as string,
    reward_amount: combo.reward_amount as number,
    tiers: (combo.tiers as number[]).map((tier) => ({ tier, name: nameByTier.get(tier) ?? `#${tier}` })),
    all_tiers: allTiers ?? [],
  };
}
