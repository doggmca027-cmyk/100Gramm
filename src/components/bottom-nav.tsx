"use client";

export type TabId = "path" | "balance" | "upgrades" | "squad" | "games";

const TABS: { id: TabId; label: string; icon: string }[] = [
  { id: "path", label: "Путь", icon: "🍾" },
  { id: "balance", label: "Баланс", icon: "💰" },
  { id: "upgrades", label: "Улучшения", icon: "⭐" },
  { id: "squad", label: "Банда", icon: "👥" },
  { id: "games", label: "Игры", icon: "🎮" },
];

export function BottomNav({
  active,
  onChange,
}: {
  active: TabId;
  onChange: (tab: TabId) => void;
}) {
  return (
    <nav className="bg-nav fixed inset-x-0 bottom-0 flex justify-around border-t border-white/5 py-2">
      {TABS.map((tab) => (
        <button
          key={tab.id}
          type="button"
          onClick={() => onChange(tab.id)}
          className={`flex flex-col items-center gap-0.5 px-3 py-1 text-xs ${
            active === tab.id ? "text-white" : "text-nav-inactive"
          }`}
        >
          <span className="text-lg">{tab.icon}</span>
          {tab.label}
        </button>
      ))}
    </nav>
  );
}
