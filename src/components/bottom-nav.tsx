"use client";

import { Compass, Wallet, Vault, Zap, Users, Dices, type LucideIcon } from "lucide-react";
import { useLanguage } from "@/lib/i18n/context";

export type TabId = "path" | "balance" | "bank" | "upgrades" | "squad" | "gangs" | "games";

// "gangs" is deliberately left out of this list — hides the tab from the
// nav bar without touching TabId, page.tsx's `tab === "gangs"` branch, or
// GangsScreen itself, so the whole feature can come back by adding one line
// here. Anything that reaches gangs some other way (e.g. a gang_<uuid>
// startapp invite link, handled server-side in
// tryJoinGangFromStartParam) is unaffected — this only hides the nav entry.
const TABS: { id: TabId; Icon: LucideIcon }[] = [
  { id: "path", Icon: Compass },
  { id: "balance", Icon: Wallet },
  { id: "bank", Icon: Vault },
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
            className={`flex flex-col items-center gap-1 rounded-xl px-1.5 py-1 text-[10px] font-medium transition-colors ${
              isActive ? "text-amber-400" : "text-neutral-500"
            }`}
          >
            <Icon
              size={19}
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
