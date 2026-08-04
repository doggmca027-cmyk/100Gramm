"use client";

import { useLanguage } from "@/lib/i18n/context";

export function GamesScreen() {
  const { t } = useLanguage();
  return (
    <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
      <p className="text-3xl">🎮</p>
      <p className="font-semibold">{t("games.title")}</p>
      <p className="text-sm text-nav-inactive">{t("games.description")}</p>
    </div>
  );
}
