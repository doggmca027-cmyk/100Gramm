"use client";

import { useState } from "react";
import { LifeBuoy } from "lucide-react";
import { openTelegramLink } from "@telegram-apps/sdk-react";
import { useLanguage } from "@/lib/i18n/context";
import { LANGUAGES, LANGUAGE_LABELS } from "@/lib/i18n/types";

const SUPPORT_BOT_URL = "https://t.me/GrammSupportBot";

/**
 * Support + language used to be two separate header icon buttons — merged
 * into one group behind a single trigger (the current language's flag) that
 * opens a bottom sheet with a "Поддержка" row on top and the language list
 * below.
 */
export function SupportLanguageMenu() {
  const { lang, setLang, t } = useLanguage();
  const [open, setOpen] = useState(false);

  function handleSupport() {
    if (openTelegramLink.isAvailable()) {
      openTelegramLink(SUPPORT_BOT_URL);
    } else {
      window.open(SUPPORT_BOT_URL, "_blank");
    }
    setOpen(false);
  }

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="gradient-surface flex h-9 w-9 items-center justify-center rounded-full text-lg"
        aria-label={t("header.supportLanguage")}
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
              <h2 className="text-base font-semibold">{t("header.supportLanguage")}</h2>
              <button
                type="button"
                onClick={() => setOpen(false)}
                className="text-nav-inactive"
                aria-label={t("common.back")}
              >
                ✕
              </button>
            </div>

            <button
              type="button"
              onClick={handleSupport}
              className="gradient-surface flex items-center gap-3 rounded-xl p-3 text-left rtl:text-right text-sm"
            >
              <LifeBuoy className="h-5 w-5 shrink-0 text-amber-400" />
              {t("header.support")}
            </button>

            <div className="my-1 h-px bg-white/5" />

            <p className="px-1 text-xs font-semibold text-nav-inactive">{t("languagePicker.title")}</p>
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
