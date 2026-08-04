"use client";

import type { PlayerState } from "@/lib/types";

export function UpgradesScreen({ state }: { state: PlayerState }) {
  const { base_slots, cycles_per_slot, max_slots } = state.season.config;
  const atCap = max_slots != null && state.wallet.slots_count >= max_slots;

  const cyclesForCurrentSlots =
    (state.wallet.slots_count - base_slots) * cycles_per_slot;
  const cyclesIntoCurrentSlot =
    state.wallet.completed_cycles_total - cyclesForCurrentSlots;
  const progressPercent = atCap
    ? 100
    : Math.min(100, (cyclesIntoCurrentSlot / cycles_per_slot) * 100);
  const cyclesRemaining = Math.max(0, cycles_per_slot - cyclesIntoCurrentSlot);

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface rounded-2xl p-5">
        <p className="text-sm text-nav-inactive">Слоты</p>
        <p className="text-3xl font-bold">{state.wallet.slots_count}</p>
        {atCap ? (
          <p className="mt-2 text-xs text-nav-inactive">Максимум слотов достигнут</p>
        ) : (
          <>
            <div className="mt-3 h-1.5 rounded-full bg-progress-bg">
              <div
                className="h-1.5 rounded-full bg-progress-fill"
                style={{ width: `${progressPercent}%` }}
              />
            </div>
            <p className="mt-2 text-xs text-nav-inactive">
              Ещё {cyclesRemaining} циклов до нового слота (+1 слот каждые{" "}
              {cycles_per_slot})
            </p>
          </>
        )}
      </div>

      <div className="gradient-surface rounded-2xl p-5 text-sm text-nav-inactive">
        <p>
          🛠 Тележка, склад и другие улучшения появятся в следующих сезонах.
        </p>
      </div>
    </div>
  );
}
