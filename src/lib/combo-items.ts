/** Icon + i18n-key mapping shared between the inventory UI and the combo game/modal. */

import { Timer, Rocket, Zap, Bot, Gift, type LucideIcon } from "lucide-react";

export const ITEM_ICON: Record<string, LucideIcon> = {
  time_skip_1pct: Timer,
  time_skip_3pct: Timer,
  time_skip_5pct: Rocket,
  time_skip_10pct: Zap,
  auto_collect_1d: Bot,
  auto_collect_3d: Bot,
};

/** Suffix used to build i18n keys: `items.<suffix>Name` / `items.<suffix>Desc`. */
export const ITEM_I18N_KEY: Record<string, string> = {
  time_skip_1pct: "timeSkip1",
  time_skip_3pct: "timeSkip3",
  time_skip_5pct: "timeSkip5",
  time_skip_10pct: "timeSkip10",
  auto_collect_1d: "autoCollect1d",
  auto_collect_3d: "autoCollect3d",
};

export function itemIcon(itemType: string): LucideIcon {
  return ITEM_ICON[itemType] ?? Gift;
}

/** `items.<suffix>Name` — pass straight into t(). */
export function itemNameKey(itemType: string): `items.${string}` {
  return `items.${ITEM_I18N_KEY[itemType] ?? itemType}Name`;
}

/** `items.<suffix>Desc` — pass straight into t(). */
export function itemDescKey(itemType: string): `items.${string}` {
  return `items.${ITEM_I18N_KEY[itemType] ?? itemType}Desc`;
}
