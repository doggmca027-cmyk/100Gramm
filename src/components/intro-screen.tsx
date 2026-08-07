"use client";

import { useState } from "react";
import { Wine, GlassWater, Hourglass, Coins, Unlock, TrendingUp, Rocket } from "lucide-react";
import { markIntroSeen } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

const FEATURE_ICONS = [GlassWater, Hourglass, Coins, Unlock, TrendingUp] as const;

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
      <h1 className="flex items-center justify-center gap-2 text-3xl font-bold">
        <Wine className="h-7 w-7 text-amber-400" />
        100ГРАМ
      </h1>

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
        <ul className="mt-4 space-y-1.5">
          {(["feature1", "feature2", "feature3", "feature4", "feature5"] as const).map((key, i) => {
            const FeatureIcon = FEATURE_ICONS[i];
            return (
              <li key={key} className="flex items-center gap-2">
                <FeatureIcon className="h-4 w-4 shrink-0 text-amber-400" />
                {t(`intro.${key}`)}
              </li>
            );
          })}
        </ul>
        <p className="mt-4">{t("intro.p5")}</p>
      </div>

      <button
        type="button"
        onClick={handleStart}
        disabled={submitting}
        className="gradient-action mt-auto flex items-center justify-center gap-2 rounded-full px-6 py-4 text-lg font-bold disabled:opacity-60"
      >
        <Rocket className="h-5 w-5" />
        {t("intro.cta")}
      </button>
    </div>
  );
}
