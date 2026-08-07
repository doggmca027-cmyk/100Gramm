"use client";

import { useState } from "react";
import { markIntroSeen } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

export function IntroScreen({ onDone }: { onDone: () => void }) {
  const [submitting, setSubmitting] = useState(false);
  const { t } = useLanguage();

  async function handleStart() {
    setSubmitting(true);
    try {
      await markIntroSeen();
    } finally {
      onDone();
    }
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto p-6 text-center">
      <h1 className="text-3xl font-bold">🍾 100ГРАМ</h1>

      <div className="gradient-surface rounded-2xl p-5 text-left rtl:text-right text-[15px] leading-relaxed">
        <p>{t("intro.p1")}</p>
        <p className="mt-3">{t("intro.p2")}</p>
        <p className="mt-4 font-semibold">{t("intro.day1Title")}</p>
        <p className="mt-2">{t("intro.p3")}</p>
        <p className="mt-3">
          {t("intro.p4prefix")}
          <span className="font-semibold text-gram">1 GRAM</span>
          {t("intro.p4suffix")}
        </p>
        <ul className="mt-4 space-y-1">
          <li>{t("intro.feature1")}</li>
          <li>{t("intro.feature2")}</li>
          <li>{t("intro.feature3")}</li>
          <li>{t("intro.feature4")}</li>
          <li>{t("intro.feature5")}</li>
        </ul>
        <p className="mt-4">{t("intro.p5")}</p>
      </div>

      <button
        type="button"
        onClick={handleStart}
        disabled={submitting}
        className="gradient-action mt-auto rounded-full px-6 py-4 text-lg font-bold disabled:opacity-60"
      >
        {t("intro.cta")}
      </button>
    </div>
  );
}
