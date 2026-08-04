"use client";

import { createContext, useCallback, useContext, useMemo, useState } from "react";
import { LANGUAGES, type Language, type Localized } from "./types";
import { translate } from "./dictionary";

const STORAGE_KEY = "100gram_lang";

function readStoredLanguage(): Language {
  if (typeof window === "undefined") return "ru";
  const stored = window.localStorage.getItem(STORAGE_KEY);
  return (LANGUAGES as readonly string[]).includes(stored ?? "") ? (stored as Language) : "ru";
}

interface LanguageContextValue {
  lang: Language;
  setLang: (lang: Language) => void;
  t: (key: Parameters<typeof translate>[1], vars?: Record<string, string | number>) => string;
  pick: (field: Localized | null | undefined) => string;
}

const LanguageContext = createContext<LanguageContextValue | null>(null);

export function LanguageProvider({ children }: { children: React.ReactNode }) {
  // Lazy initializer reads localStorage once on mount — not impure render,
  // and avoids the classic hydration-mismatch trap of reading it eagerly.
  const [lang, setLangState] = useState<Language>(() => readStoredLanguage());

  const setLang = useCallback((next: Language) => {
    setLangState(next);
    if (typeof window !== "undefined") {
      window.localStorage.setItem(STORAGE_KEY, next);
    }
  }, []);

  const value = useMemo<LanguageContextValue>(
    () => ({
      lang,
      setLang,
      t: (key, vars) => translate(lang, key, vars),
      pick: (field) => (field ? (field[lang] ?? field.ru) : ""),
    }),
    [lang, setLang],
  );

  return <LanguageContext.Provider value={value}>{children}</LanguageContext.Provider>;
}

export function useLanguage(): LanguageContextValue {
  const ctx = useContext(LanguageContext);
  if (!ctx) {
    throw new Error("useLanguage must be used within a LanguageProvider");
  }
  return ctx;
}
