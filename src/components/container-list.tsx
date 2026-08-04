"use client";

import { useState } from "react";
import type { Container, PlayerState } from "@/lib/types";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import { openContainer } from "@/lib/api-client";

const CONTAINER_ICON: Record<string, string> = {
  trash: "🗑",
  old: "📦",
  locked: "🔒",
  golden: "💎",
};

function ContainerRow({
  container,
  onOpened,
}: {
  container: Container;
  onOpened: (state: PlayerState) => void;
}) {
  const [opening, setOpening] = useState(false);
  const remaining = useCountdown(container.opens_at);
  const ready = remaining <= 0;

  async function handleOpen() {
    setOpening(true);
    try {
      const result = await openContainer(container.id);
      onOpened(result.state);
    } catch {
      // no-op: button just re-enables
    } finally {
      setOpening(false);
    }
  }

  return (
    <div className="gradient-surface flex items-center justify-between rounded-xl p-3">
      <span className="text-sm">
        {CONTAINER_ICON[container.code] ?? "📦"} {container.name}
      </span>
      <button
        type="button"
        onClick={handleOpen}
        disabled={!ready || opening}
        className="gradient-action rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-40"
      >
        {ready ? "Открыть" : formatDuration(remaining)}
      </button>
    </div>
  );
}

export function ContainerList({
  containers,
  onStateChange,
}: {
  containers: Container[];
  onStateChange: (state: PlayerState) => void;
}) {
  if (containers.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">
        📦 Контейнеры
      </h2>
      {containers.map((container) => (
        <ContainerRow key={container.id} container={container} onOpened={onStateChange} />
      ))}
    </div>
  );
}
