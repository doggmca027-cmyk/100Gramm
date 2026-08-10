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
