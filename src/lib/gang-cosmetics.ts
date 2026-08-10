import type { GangCosmeticFields } from "./types";

/**
 * code -> Tailwind glow classes, mirrors gang_cosmetics_catalog's `glow`
 * column (0066_district_wars_monetization.sql). Kept client-side and
 * hand-synced rather than fetched per-render — there are only 6 entries,
 * and every screen that shows a gang badge (Топ Банд, Карта Районов, the
 * gang's own header) would otherwise need its own cosmetics-catalog
 * round trip just to render a ring. GET /api/gangs/cosmetics (fetchGangCosmetics)
 * is still the source of truth for names/prices in the shop itself.
 */
const COSMETIC_GLOW: Record<string, string> = {
  golden_crown: "ring-2 ring-amber-400 shadow-[0_0_14px_2px_rgba(250,204,21,0.55)]",
  diamond_skull: "ring-2 ring-cyan-300 shadow-[0_0_14px_2px_rgba(103,232,249,0.55)]",
  phoenix: "ring-2 ring-orange-400 shadow-[0_0_14px_2px_rgba(251,146,60,0.55)]",
  neon_gold: "ring-2 ring-amber-400 shadow-[0_0_14px_2px_rgba(250,204,21,0.55)]",
  neon_purple: "ring-2 ring-purple-400 shadow-[0_0_14px_2px_rgba(192,132,252,0.55)]",
  neon_red: "ring-2 ring-red-400 shadow-[0_0_14px_2px_rgba(248,113,113,0.55)]",
};

/** Frame takes priority over the premium avatar's own glow (a gang can own both; the frame is the more visible flex). */
export function gangGlowClassName(fields: Partial<GangCosmeticFields> | null | undefined): string {
  if (!fields) return "";
  const code = fields.frame_id ?? fields.premium_avatar_id;
  return code ? (COSMETIC_GLOW[code] ?? "") : "";
}
