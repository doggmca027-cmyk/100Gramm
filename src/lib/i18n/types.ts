export const LANGUAGES = ["ru", "en", "tr", "id", "ar"] as const;
export type Language = (typeof LANGUAGES)[number];

export const LANGUAGE_LABELS: Record<Language, { flag: string; label: string }> = {
  ru: { flag: "🇷🇺", label: "Русский" },
  en: { flag: "🇬🇧", label: "English" },
  tr: { flag: "🇹🇷", label: "Türkçe" },
  id: { flag: "🇮🇩", label: "Bahasa Indonesia" },
  ar: { flag: "🇸🇦", label: "العربية" },
};

export const LANGUAGE_LOCALE: Record<Language, string> = {
  ru: "ru-RU",
  en: "en-US",
  tr: "tr-TR",
  id: "id-ID",
  ar: "ar-SA",
};

/** Right-to-left languages — drives the <html dir> attribute, see context.tsx. */
export const RTL_LANGUAGES: readonly Language[] = ["ar"];

/** DB content translated into all 5 languages (ru is always the base/fallback). */
export interface Localized {
  ru: string;
  en: string;
  tr: string;
  id: string;
  ar: string;
}
