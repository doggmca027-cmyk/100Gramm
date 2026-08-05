/** Icon + i18n-key mapping shared between the inventory UI and the combo game/modal. */

export const ITEM_ICON: Record<string, string> = {
  time_skip_1pct: "⏱️",
  time_skip_3pct: "⏱️",
  time_skip_5pct: "🚀",
  time_skip_10pct: "⚡",
  auto_collect_1d: "🤖",
  auto_collect_3d: "🤖",
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

export function itemIcon(itemType: string): string {
  return ITEM_ICON[itemType] ?? "🎁";
}

/** `items.<suffix>Name` — pass straight into t(). */
export function itemNameKey(itemType: string): `items.${string}` {
  return `items.${ITEM_I18N_KEY[itemType] ?? itemType}Name`;
}

/** `items.<suffix>Desc` — pass straight into t(). */
export function itemDescKey(itemType: string): `items.${string}` {
  return `items.${ITEM_I18N_KEY[itemType] ?? itemType}Desc`;
}
