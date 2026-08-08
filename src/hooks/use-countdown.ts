"use client";

import { useEffect, useState } from "react";
import { useLanguage } from "@/lib/i18n/context";

function secondsUntil(iso: string): number {
  return Math.max(0, Math.floor((new Date(iso).getTime() - Date.now()) / 1000));
}

export function useCountdown(endsAt: string): number {
  // `tick` only exists to force a re-render every second — the actual
  // returned value is always computed fresh from the current `endsAt` on
  // every render, never stored in state itself. That's deliberate: an
  // earlier version cached `remaining` in useState (seeded once via a lazy
  // initializer), which meant that when `endsAt` changed on an
  // already-mounted component — e.g. a task moving straight from
  // "unverified" to "pending" with a real available_at — the stale cached
  // value stuck around for up to ~1s, until the interval's first tick.
  // Computing at render time removes that lag entirely, and keeps the
  // effect itself doing only what effects should (a subscription/timer),
  // not a synchronous setState in the effect body.
  const [, setTick] = useState(0);

  useEffect(() => {
    const interval = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(interval);
  }, []);

  return secondsUntil(endsAt);
}

function elapsedPercent(startIso: string, totalHours: number): number {
  if (totalHours <= 0) return 100;
  const elapsedMs = Date.now() - new Date(startIso).getTime();
  return Math.min(100, Math.max(0, (elapsedMs / (totalHours * 3600_000)) * 100));
}

/** 0-100 progress from `startIso` towards `startIso + totalHours`, ticking. */
export function useElapsedPercent(startIso: string, totalHours: number): number {
  // Same render-time-computation approach as useCountdown above, and for
  // the same reason — no cached value that can go stale for up to 30s
  // when startIso/totalHours change on an already-mounted component.
  const [, setTick] = useState(0);

  useEffect(() => {
    const interval = setInterval(() => setTick((t) => t + 1), 30_000);
    return () => clearInterval(interval);
  }, []);

  return elapsedPercent(startIso, totalHours);
}

/** Localized h/m/s labels, e.g. `{ h: "h", m: "m", s: "s" }` — pull from
 * `t("common.hourShort")` / `t("common.minuteShort")` / `t("common.secondShort")`
 * at the call site so the unit abbreviations follow the active language
 * instead of always reading as Russian. */
export interface DurationUnits {
  h: string;
  m: string;
  s: string;
}

export function formatDuration(totalSeconds: number, units: DurationUnits): string {
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = Math.floor(totalSeconds % 60);
  if (h > 0) return `${h}${units.h} ${m}${units.m}`;
  if (m > 0) return `${m}${units.m} ${s}${units.s}`;
  return `${s}${units.s}`;
}

/** Reads the active language's h/m/s abbreviations for `formatDuration`. */
export function useDurationUnits(): DurationUnits {
  const { t } = useLanguage();
  return {
    h: t("common.hourShort"),
    m: t("common.minuteShort"),
    s: t("common.secondShort"),
  };
}
