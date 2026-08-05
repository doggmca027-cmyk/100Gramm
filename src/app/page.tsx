"use client";

import { useState } from "react";
import { usePlayerState } from "@/hooks/use-player-state";
import { IntroScreen } from "@/components/intro-screen";
import { AppHeader } from "@/components/app-header";
import { BottomNav, type TabId } from "@/components/bottom-nav";
import { PathScreen } from "@/components/path-screen";
import { BalanceScreen } from "@/components/balance-screen";
import { UpgradesScreen } from "@/components/upgrades-screen";
import { SquadScreen } from "@/components/squad-screen";
import { GamesScreen } from "@/components/games-screen";
import { AdminScreen } from "@/components/admin-screen";
import { useLanguage } from "@/lib/i18n/context";

export default function Home() {
  const { t } = useLanguage();
  const { state, loading, error, refresh, setState } = usePlayerState();
  const [tab, setTab] = useState<TabId>("path");
  const [introDone, setIntroDone] = useState(false);
  const [adminOpen, setAdminOpen] = useState(false);

  if (loading) {
    return (
      <main className="flex flex-1 items-center justify-center">
        <p className="text-nav-inactive">{t("common.loading")}</p>
      </main>
    );
  }

  if (error || !state) {
    return (
      <main className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
        <p className="text-nav-inactive">{t("common.loadFailed")}</p>
        <button
          type="button"
          onClick={refresh}
          className="gradient-action rounded-full px-4 py-2 text-sm font-semibold"
        >
          {t("common.retry")}
        </button>
      </main>
    );
  }

  if (!state.wallet.has_seen_intro && !introDone) {
    return <IntroScreen onDone={() => setIntroDone(true)} />;
  }

  return (
    <>
      <AppHeader state={state} onOpenAdmin={() => setAdminOpen(true)} />
      {adminOpen ? (
        <AdminScreen onBack={() => setAdminOpen(false)} />
      ) : (
        <>
          <main className="flex min-h-0 flex-1 flex-col">
            {tab === "path" && <PathScreen state={state} onStateChange={setState} />}
            {tab === "balance" && (
              <BalanceScreen state={state} onStateChange={setState} />
            )}
            {tab === "upgrades" && <UpgradesScreen state={state} />}
            {tab === "squad" && <SquadScreen state={state} />}
            {tab === "games" && (
              <GamesScreen state={state} onNavigateToPath={() => setTab("path")} />
            )}
          </main>
          <BottomNav active={tab} onChange={setTab} />
        </>
      )}
    </>
  );
}
