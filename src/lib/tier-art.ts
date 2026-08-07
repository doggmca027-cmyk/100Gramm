// Single place to plug in real art once it's supplied — fill a tier's entry
// with a URL and the card/detail screen will use it instead of the emoji
// placeholder automatically.
export const TIER_IMAGE_URL: Partial<Record<number, string>> = {
  1: "/products/1-bottle.jpg",
  2: "/products/2-crate.jpg",
  3: "/products/3-cart.jpg",
  4: "/products/4-kiosk.jpg",
  5: "/products/5-bar.jpg",
  6: "/products/6-liquor.jpg",
  7: "/products/7-restaurant.jpg",
  8: "/products/8-palace.jpg",
};

export const GRAM_COIN_IMAGE = "/products/gram-coin.jpg";
export const SQUAD_BANNER_IMAGE = "/products/squad-banner.jpg";

import {
  Wine,
  Package,
  ShoppingCart,
  Home,
  Beer,
  Store,
  Building2,
  Crown,
  Sparkles,
  type LucideIcon,
} from "lucide-react";

export const TIER_ICON: Record<number, LucideIcon> = {
  1: Wine,
  2: Package,
  3: ShoppingCart,
  4: Home,
  5: Beer,
  6: Store,
  7: Building2,
  8: Crown,
};

/** Fallback for an out-of-range tier — same "generic tier" role the 🎴 emoji used to play. */
export const DEFAULT_TIER_ICON: LucideIcon = Sparkles;

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

// Suffix of the productDetail.rarity* translation key for each tier.
export const TIER_RARITY_KEY: Record<number, string> = {
  1: "Common",
  2: "Common",
  3: "Uncommon",
  4: "Uncommon",
  5: "Rare",
  6: "Rare",
  7: "Epic",
  8: "Legendary",
};
