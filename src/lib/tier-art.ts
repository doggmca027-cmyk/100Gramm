// Single place to plug in real art once it's supplied — fill a tier's entry
// with a URL and the card/detail screen will use it instead of the emoji
// placeholder automatically.
export const TIER_IMAGE_URL: Partial<Record<number, string>> = {};

export const TIER_ICON: Record<number, string> = {
  1: "🍾",
  2: "📦",
  3: "🛒",
  4: "🏚",
  5: "🍺",
  6: "🏪",
  7: "🏢",
  8: "👑",
};

export const TIER_ACCENT: Record<number, string> = {
  1: "#8b7765",
  2: "#c47a4a",
  3: "#bfc7d5",
  4: "#ffd166",
  5: "#ff9f43",
  6: "#4da3ff",
  7: "#b05cff",
  8: "#ffd700",
};

export const TIER_RARITY: Record<number, string> = {
  1: "Обычное",
  2: "Обычное",
  3: "Необычное",
  4: "Необычное",
  5: "Редкое",
  6: "Редкое",
  7: "Эпическое",
  8: "Легендарное",
};
