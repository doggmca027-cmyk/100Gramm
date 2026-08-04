// Ring color (gradient stops) around the profile avatar, keyed by
// rank.level (1 = 🥴 Бомж ... 5 = 👑 Император). Deliberately distinct from
// TIER_ACCENT in tier-art.ts — this is about story rank, not product tier.
export const RANK_RING: Record<number, [string, string]> = {
  1: ["#5c5a6e", "#5c5a6e"],
  2: ["#a8785a", "#a8785a"],
  3: ["#b9c2d0", "#b9c2d0"],
  4: ["#ffcf5c", "#ffcf5c"],
  5: ["#ffd700", "#ff4fd8"],
};

export function rankRingGradient(level: number | undefined): string {
  const [from, to] = RANK_RING[level ?? 1] ?? RANK_RING[1];
  return `linear-gradient(135deg, ${from}, ${to})`;
}
