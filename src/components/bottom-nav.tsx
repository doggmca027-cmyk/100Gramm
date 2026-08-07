"use client";

import { Compass, Wallet, Zap, Users, Dices, type LucideIcon } from "lucide-react";
import { useLanguage } from "@/lib/i18n/context";

export type TabId = "path" | "balance" | "upgrades" | "squad" | "games";

const TABS: { id: TabId; Icon: LucideIcon }[] = [
  { id: "path", Icon: Compass },
  { id: "balance", Icon: Wallet },
  { id: "upgrades", Icon: Zap },
  { id: "squad", Icon: Users },
  { id: "games", Icon: Dices },
];

export function BottomNav({
  active,
  onChange,
}: {
  active: TabId;
  onChange: (tab: TabId) => void;
}) {
  const { t } = useLanguage();

  return (
    <nav className="fixed inset-x-0 bottom-0 flex justify-around border-t border-purple-900/30 bg-[#0d0d12]/90 py-2 backdrop-blur-md">
      {TABS.map(({ id, Icon }) => {
        const isActive = active === id;
        return (
          <button
            key={id}
            type="button"
            onClick={() => onChange(id)}
            className={`flex flex-col items-center gap-1 rounded-xl px-3 py-1 text-xs font-medium transition-colors ${
              isActive ? "text-amber-400" : "text-neutral-500"
            }`}
          >
            <Icon
              size={20}
              strokeWidth={isActive ? 2.25 : 2}
              className={`transition-transform duration-200 ${
                isActive ? "scale-105 drop-shadow-[0_0_8px_rgba(245,158,11,0.6)]" : ""
              }`}
            />
            {t(`nav.${id}`)}
          </button>
        );
      })}
    </nav>
  );
}
