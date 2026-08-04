"use client";

import { useEffect, useState } from "react";

function secondsUntil(iso: string): number {
  return Math.max(0, Math.floor((new Date(iso).getTime() - Date.now()) / 1000));
}

export function useCountdown(endsAt: string): number {
  const [remaining, setRemaining] = useState(() => secondsUntil(endsAt));

  useEffect(() => {
    const interval = setInterval(() => setRemaining(secondsUntil(endsAt)), 1000);
    return () => clearInterval(interval);
  }, [endsAt]);

  return remaining;
}

function elapsedPercent(startIso: string, totalHours: number): number {
  if (totalHours <= 0) return 100;
  const elapsedMs = Date.now() - new Date(startIso).getTime();
  return Math.min(100, Math.max(0, (elapsedMs / (totalHours * 3600_000)) * 100));
}

/** 0-100 progress from `startIso` towards `startIso + totalHours`, ticking. */
export function useElapsedPercent(startIso: string, totalHours: number): number {
  const [percent, setPercent] = useState(() => elapsedPercent(startIso, totalHours));

  useEffect(() => {
    const interval = setInterval(
      () => setPercent(elapsedPercent(startIso, totalHours)),
      30_000,
    );
    return () => clearInterval(interval);
  }, [startIso, totalHours]);

  return percent;
}

export function formatDuration(totalSeconds: number): string {
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = Math.floor(totalSeconds % 60);
  if (h > 0) return `${h}ч ${m}м`;
  if (m > 0) return `${m}м ${s}с`;
  return `${s}с`;
}
