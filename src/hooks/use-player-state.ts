"use client";

import { useCallback, useEffect, useState } from "react";
import { fetchState } from "@/lib/api-client";
import type { PlayerState } from "@/lib/types";

export function usePlayerState() {
  const [state, setState] = useState<PlayerState | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const next = await fetchState();
      setState(next);
      setError(null);
    } catch {
      setError("state_fetch_failed");
    } finally {
      setLoading(false);
    }
  }, []);

  // Cycles resolve lazily server-side; poll so completed cycles/slots/unlocks
  // show up without the player having to manually reopen the app. Kept as a
  // self-contained async closure (not a call to `refresh`) so state updates
  // stay behind the fetch's await boundary rather than firing synchronously
  // in the effect body.
  useEffect(() => {
    let cancelled = false;

    async function load() {
      try {
        const next = await fetchState();
        if (cancelled) return;
        setState(next);
        setError(null);
      } catch {
        if (!cancelled) setError("state_fetch_failed");
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    load();
    const interval = setInterval(load, 30_000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, []);

  return { state, loading, error, refresh, setState };
}
