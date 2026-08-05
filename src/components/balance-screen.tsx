"use client";

import { useState } from "react";
import Image from "next/image";
import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { QuestList } from "./quest-list";
import { PartnerTasksSection } from "./partner-tasks-section";
import { SystemTasksSection } from "./system-tasks-section";
import { ComingSoonSection } from "./coming-soon-section";
import { HistoryModal } from "./history-modal";
import { WalletModal } from "./wallet-modal";
import { WalletConnectModal } from "./wallet-connect-modal";
import { GRAM_COIN_IMAGE, SQUAD_BANNER_IMAGE } from "@/lib/tier-art";
import { useTonAddress, useTonConnectUI } from "@tonconnect/ui-react";

export function BalanceScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [historyOpen, setHistoryOpen] = useState(false);
  const [walletMode, setWalletMode] = useState<"deposit" | "withdraw" | null>(null);
  const [walletConnectOpen, setWalletConnectOpen] = useState(false);
  const [tonConnectUI] = useTonConnectUI();
  const tonAddress = useTonAddress();

  // Not connected -> jump straight into TonConnect's own pairing modal.
  // Connected -> our modal (status/disconnect + the TON deposit form).
  function handleWalletButtonClick() {
    if (tonAddress) {
      setWalletConnectOpen(true);
    } else {
      tonConnectUI.openModal();
    }
  }

  const balance = state.wallet.balance ?? 0;
  const totalEarned = state.wallet.total_earned ?? 0;
  const profit24h = state.stats?.profit_24h ?? 0;
  const totalSlotsUsed = state.wallet.total_slots_used ?? 0;
  const totalSlotsOpen = state.wallet.total_slots_open ?? 0;

  return (
    <div className="flex flex-1 flex-col gap-5 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface flex items-center justify-between rounded-2xl p-5">
        <div>
          <p className="text-xs text-nav-inactive">{t("balance.yourBalance")}</p>
          <p className="gradient-gram bg-clip-text text-3xl font-bold text-transparent">
            {balance.toFixed(2)}
          </p>
          <p className="text-xs text-nav-inactive">{t("common.gram")}</p>
        </div>
        <Image
          src={GRAM_COIN_IMAGE}
          alt=""
          width={80}
          height={80}
          className="h-20 w-20 rounded-xl object-cover"
        />
      </div>

      <div className="grid grid-cols-4 gap-2">
        <button
          type="button"
          onClick={() => setWalletMode("deposit")}
          className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-3 text-xs"
        >
          <span className="text-lg">⬆️</span>
          {t("balance.topUp")}
        </button>
        <button
          type="button"
          onClick={() => setWalletMode("withdraw")}
          className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-3 text-xs"
        >
          <span className="text-lg">⬇️</span>
          {t("balance.withdraw")}
        </button>
        <button
          type="button"
          onClick={handleWalletButtonClick}
          className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-3 text-xs"
        >
          <span className="text-lg">{tonAddress ? "✅" : "👛"}</span>
          {t("walletConnect.navLabel")}
        </button>
        <button
          type="button"
          onClick={() => setHistoryOpen(true)}
          className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-3 text-xs"
        >
          <span className="text-lg">📜</span>
          {t("balance.history")}
        </button>
      </div>

      <div className="flex flex-col gap-2">
        <h2 className="px-1 text-sm font-semibold text-nav-inactive">{t("balance.statistics")}</h2>
        <div className="gradient-surface flex flex-col divide-y divide-white/5 rounded-xl">
          {[
            [t("balance.cyclesCompleted"), `${state.wallet.completed_cycles_total}`],
            [t("balance.totalEarned"), `${totalEarned.toFixed(2)} ${t("common.gram")}`],
            [t("balance.profit24h"), `${profit24h.toFixed(2)} ${t("common.gram")}`],
            [t("balance.activeSlots"), `${totalSlotsUsed} / ${totalSlotsOpen}`],
          ].map(([label, value]) => (
            <div key={label} className="flex items-center justify-between p-3 text-sm">
              <span className="text-nav-inactive">{label}</span>
              <span className="text-profit font-semibold">{value}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="relative overflow-hidden rounded-2xl">
        <Image
          src={SQUAD_BANNER_IMAGE}
          alt=""
          width={600}
          height={300}
          className="h-32 w-full object-cover"
        />
        <div className="absolute inset-0 flex flex-col justify-end bg-gradient-to-t from-black/90 via-black/40 to-transparent p-4">
          <p className="text-sm font-semibold">{t("balance.friendBonusTitle")}</p>
          <p className="text-xs text-nav-inactive">
            {t("balance.friendBonusText")} <span className="font-semibold text-gram">+10%</span>{" "}
            {t("balance.friendBonusSuffix")}
          </p>
        </div>
      </div>

      <QuestList quests={state.quests} onStateChange={onStateChange} />
      <PartnerTasksSection tasks={state.partner_tasks} onStateChange={onStateChange} />
      <SystemTasksSection tasks={state.system_tasks} onStateChange={onStateChange} />
      <ComingSoonSection
        icon="📦"
        title={t("containers.title")}
        description={t("containers.comingSoon")}
      />

      {historyOpen && <HistoryModal onClose={() => setHistoryOpen(false)} />}
      {walletMode && (
        <WalletModal
          mode={walletMode}
          state={state}
          onStateChange={onStateChange}
          onClose={() => setWalletMode(null)}
        />
      )}
      {walletConnectOpen && (
        <WalletConnectModal onClose={() => setWalletConnectOpen(false)} />
      )}
    </div>
  );
}
