import type { HistoryEntry, PlayerState } from "./types";

export class ApiError extends Error {
  constructor(public code: string) {
    super(code);
  }
}

async function request<T>(input: string, init?: RequestInit): Promise<T> {
  const res = await fetch(input, {
    ...init,
    credentials: "include",
    headers: { "Content-Type": "application/json", ...init?.headers },
  });

  if (!res.ok) {
    const body = await res.json().catch(() => null);
    throw new ApiError(body?.error ?? `http_${res.status}`);
  }

  return res.json() as Promise<T>;
}

export function fetchState() {
  return request<PlayerState>("/api/state");
}

export function startCycle(tier: number) {
  return request<{ cycleId: string; state: PlayerState }>("/api/cycles/start", {
    method: "POST",
    body: JSON.stringify({ tier }),
  });
}

export function openContainer(id: string) {
  return request<{ reward: number; state: PlayerState }>(`/api/containers/${id}/open`, {
    method: "POST",
  });
}

export function claimQuest(id: string) {
  return request<{ reward: number; state: PlayerState }>(`/api/quests/${id}/claim`, {
    method: "POST",
  });
}

export function markIntroSeen() {
  return request<{ ok: true }>("/api/intro/seen", { method: "POST" });
}

export interface LeaderboardEntry {
  display_name: string;
  total_earned: number;
  completed_cycles_total: number;
}

export function fetchLeaderboard(metric: "total_earned" | "completed_cycles_total" = "total_earned") {
  return request<LeaderboardEntry[]>(`/api/leaderboard?metric=${metric}`);
}

export function fetchHistory() {
  return request<HistoryEntry[]>("/api/history");
}
