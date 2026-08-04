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
    <nav className="bg-nav/90 fixed inset-x-0 bottom-0 flex justify-around border-t border-border py-2 backdrop-blur-md">
      {TABS.map((tab) => (
        <button
          key={tab.id}
          type="button"
          onClick={() => onChange(tab.id)}
          className={`flex flex-col items-center gap-0.5 rounded-xl px-3 py-1 text-xs transition-colors ${
            active === tab.id ? "text-white" : "text-nav-inactive"
          }`}
          style={active === tab.id ? { textShadow: "0 0 12px #9b35ff" } : undefined}
        >
          <span className="text-lg">{tab.icon}</span>
          {tab.label}
        </button>
      ))}
    </nav>
  );
}
