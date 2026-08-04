export const LANGUAGES = ["ru", "en", "tr", "id"] as const;
export type Language = (typeof LANGUAGES)[number];

export const LANGUAGE_LABELS: Record<Language, { flag: string; label: string }> = {
  ru: { flag: "🇷🇺", label: "Русский" },
  en: { flag: "🇬🇧", label: "English" },
  tr: { flag: "🇹🇷", label: "Türkçe" },
  id: { flag: "🇮🇩", label: "Bahasa Indonesia" },
};

export const LANGUAGE_LOCALE: Record<Language, string> = {
  ru: "ru-RU",
  en: "en-US",
  tr: "tr-TR",
  id: "id-ID",
};

/** DB content translated into all 4 languages (ru is always the base/fallback). */
export interface Localized {
  ru: string;
  en: string;
  tr: string;
  id: string;
}
