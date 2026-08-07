"use client";

import { useState } from "react";
import { useLanguage } from "@/lib/i18n/context";
import { LANGUAGES, LANGUAGE_LABELS } from "@/lib/i18n/types";

export function LanguageSwitcher() {
  const { lang, setLang, t } = useLanguage();
  const [open, setOpen] = useState(false);

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="gradient-surface flex h-9 w-9 items-center justify-center rounded-full text-lg"
        aria-label={t("header.language")}
      >
        {LANGUAGE_LABELS[lang].flag}
      </button>

      {open && (
        <div
          className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60"
          onClick={() => setOpen(false)}
        >
          <div
            className="bg-nav flex flex-col gap-2 rounded-t-2xl p-4"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between">
              <h2 className="text-base font-semibold">{t("languagePicker.title")}</h2>
              <button
                type="button"
                onClick={() => setOpen(false)}
                className="text-nav-inactive"
                aria-label={t("common.back")}
              >
                ✕
              </button>
            </div>
            {LANGUAGES.map((code) => (
              <button
                key={code}
                type="button"
                onClick={() => {
                  setLang(code);
                  setOpen(false);
                }}
                className={`flex items-center gap-3 rounded-xl p-3 text-left rtl:text-right text-sm ${
                  code === lang ? "gradient-action" : "gradient-surface"
                }`}
              >
                <span className="text-xl">{LANGUAGE_LABELS[code].flag}</span>
                {LANGUAGE_LABELS[code].label}
              </button>
            ))}
          </div>
        </div>
      )}
    </>
  );
}
