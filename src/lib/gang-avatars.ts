import type { GangAvatarId } from "./types";

/**
 * Client-side mirror of the avatar_id CHECK constraint in create_gang
 * (0058_gangs.sql) — UI-only, for populating the picker grid. The server
 * validates its own whitelist regardless and silently falls back to
 * 'default_gang' for anything outside it, same "never trust the client"
 * posture as every other RPC in this schema.
 */
export const GANG_AVATAR_IDS: GangAvatarId[] = [
  "default_gang",
  "skull",
  "crown",
  "flame",
  "shield",
  "swords",
  "ghost",
  "anchor",
];

/** GRAM cost to found a gang ("5 TON" — see create_gang's v_cost comment in 0058_gangs.sql for why it's GRAM, not a separate currency). UI-only: disables the create button early, the RPC is what actually enforces it. */
export const GANG_CREATION_COST = 5;

/** +5 member slots per purchase, 1 GRAM each, paid from the gang's own bank — see upgrade_gang_capacity (0062_gang_capacity_upgrade.sql). UI-only mirrors, same posture as GANG_CREATION_COST above. */
export const GANG_SLOT_PACK_SIZE = 5;
export const GANG_SLOT_PACK_COST = 1;

/** +1 co_leader slot, from the leader's own balance — see purchase_co_leader_slot (0066_district_wars_monetization.sql). UI-only mirror. */
export const CO_LEADER_SLOT_COST = 3;

/** One-time upgrade to 30% APY gang bank interest (from 10% base) — see purchase_vip_treasury (0066_district_wars_monetization.sql). UI-only mirror. */
export const VIP_TREASURY_COST = 10;

/** Battle boost prices — see activate_district_boost (0066_district_wars_monetization.sql). UI-only mirrors. */
export const AIRSTRIKE_2X_COST = 2;
export const AIRSTRIKE_3X_COST = 5;
export const ENGINEER_SHIELD_COST = 3;
export const MERCENARY_BOT_COST = 8;

/**
 * Weekly Syndicate leaderboard — see buy_direct_influence/
 * finalize_weekly_leaderboard_season (0070_syndicate_weekly_leaderboard.sql,
 * doubled to 200 in 0072_double_weekly_prize_pool.sql). This is only a
 * pre-load fallback for the banner (get_syndicate_leaderboard's own
 * `prize_pool_ton` is the source of truth once the request resolves,
 * see syndicate-leaderboard-panel.tsx) — per-rank prize amounts always
 * come from the server (SyndicateLeaderboardEntry.prize_ton /
 * SyndicateLeaderboardMyGang.prize_ton), never mirrored here, so there's
 * only one number to keep in sync instead of a whole 15-row table.
 */
export const WEEKLY_PRIZE_POOL_TON = 200;
/**
 * Minimum "Забустить Влияние" purchase — buy_direct_influence rejects less.
 * Repriced from 1 to 5 in 0074_reprice_direct_influence.sql: 200 points now
 * costs 5 TON (was 1), so the floor moves in lockstep with the rate below.
 */
export const DIRECT_INFLUENCE_MIN_TON = 5;
/**
 * Influence Points minted per 1 GRAM ("TON") of direct purchase. Repriced
 * from 200 to 40 in 0074_reprice_direct_influence.sql (a straight 5x price
 * hike) — 5 TON still buys exactly 200 points, same as 1 TON used to.
 */
export const DIRECT_INFLUENCE_RATE = 40;
