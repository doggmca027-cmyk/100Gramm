"use client";

import { useEffect, useState } from "react";
import { Crown, Trophy, Coins, RotateCw, type LucideIcon } from "lucide-react";
import { fetchLeaderboard, type LeaderboardEntry, type LeaderboardMetric } from "@/lib/api-client";
import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { SyndicateLeaderboardPanel } from "./syndicate-leaderboard-panel";

const RANK_BADGE_CLASS: Record<number, string> = {
  1: "bg-gram text-bg",
  2: "bg-[#c9ccd6] text-bg",
  3: "bg-[#cd8a4f] text-bg",
};

/** "syndicates" is a whole separate panel (SyndicateLeaderboardPanel), not another LeaderboardMetric — the individual-player ranking below only ever drives the first two tabs. */
type LeaderboardTab = LeaderboardMetric | "syndicates";

// "syndicates" is deliberately left out of this list — hides the tab
// button without touching LeaderboardTab, the tab === "syndicates" render
// branch below, or SyndicateLeaderboardPanel/its API route, so it can come
// back by adding one line here.
const TABS: { tab: LeaderboardTab; labelKey: "leaderboard.tabEarned" | "leaderboard.tabCycles" | "leaderboard.syndicateTab"; Icon: LucideIcon }[] = [
  { tab: "total_earned", labelKey: "leaderboard.tabEarned", Icon: Coins },
  { tab: "cycles_launched_total", labelKey: "leaderboard.tabCycles", Icon: RotateCw },
];

/** Score text for one entry, matching whichever metric the active tab is ranked by. */
function scoreText(
  entry: LeaderboardEntry,
  metric: LeaderboardMetric,
  t: ReturnType<typeof useLanguage>["t"],
): string {
  if (metric === "cycles_launched_total") {
    return `${entry.cycles_launched_total} ${t("leaderboard.cyclesUnit")}`;
  }
  return `${entry.total_earned.toFixed(3)} ${t("common.gram")}`;
}

/** Telegram photo if we have one and it loads; otherwise the name's first letter. */
function LeaderboardAvatar({
  name,
  photoUrl,
  sizeClassName,
  textClassName,
}: {
  name: string;
  photoUrl: string | null;
  sizeClassName: string;
  textClassName: string;
}) {
  const [failed, setFailed] = useState(false);
  const showPhoto = photoUrl && !failed;

  return (
    <div className={`${sizeClassName} shrink-0 overflow-hidden rounded-full bg-progress-bg`}>
      {showPhoto ? (
        // Telegram photo URLs come from an unpredictable CDN host; a plain
        // <img> avoids maintaining a remotePatterns allowlist for it.
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={photoUrl}
          alt=""
          className="h-full w-full object-cover"
          onError={() => setFailed(true)}
        />
      ) : (
        <div className={`gradient-action flex h-full w-full items-center justify-center font-bold ${textClassName}`}>
          {name.charAt(0).toUpperCase()}
        </div>
      )}
    </div>
  );
}

function PodiumSlot({
  entry,
  rank,
  metric,
  t,
}: {
  entry: LeaderboardEntry;
  rank: 1 | 2 | 3;
  metric: LeaderboardMetric;
  t: ReturnType<typeof useLanguage>["t"];
}) {
  const isFirst = rank === 1;

  return (
    <div className={`flex flex-col items-center gap-1 ${isFirst ? "" : "pb-3"}`}>
      {isFirst && <Crown className="h-5 w-5 text-amber-400" />}
      <div className="relative">
        <LeaderboardAvatar
          name={entry.display_name}
          photoUrl={entry.photo_url}
          sizeClassName={isFirst ? "h-20 w-20" : "h-16 w-16"}
          textClassName={isFirst ? "text-2xl" : "text-xl"}
        />
        <span
          className={`absolute -bottom-1 -right-1 flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ring-2 ring-bg rtl:right-auto rtl:-left-1 ${RANK_BADGE_CLASS[rank]}`}
        >
          {rank}
        </span>
      </div>
      <p className={`max-w-[84px] truncate text-center font-semibold ${isFirst ? "text-sm" : "text-xs"}`}>
        {entry.display_name?.trim() ? entry.display_name.trim() : t("common.playerFallback")}
      </p>
      <p className="text-xs text-gram">{scoreText(entry, metric, t)}</p>
    </div>
  );
}

export function LeaderboardScreen({
  state,
  onStateChange,
  onBack,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
  onBack: () => void;
}) {
  const { t } = useLanguage();
  const [tab, setTab] = useState<LeaderboardTab>("total_earned");
  const [entries, setEntries] = useState<LeaderboardEntry[] | null>(null);
  const metric: LeaderboardMetric | null = tab === "syndicates" ? null : tab;

  useEffect(() => {
    if (metric === null) return;
    // Guards against a stale response landing after the user has already
    // switched tabs again — without this, a slow "cycles" request that
    // resolves after a later "earnings" request would overwrite the
    // earnings tab with cycles-ranked data. Same idiom as use-player-state.ts.
    let cancelled = false;
    fetchLeaderboard(metric)
      .then((data) => {
        if (!cancelled) setEntries(data);
      })
      .catch(() => {
        if (!cancelled) setEntries([]);
      });
    return () => {
      cancelled = true;
    };
  }, [metric]);

  // Reset to the loading state from the tab click itself (a real event
  // handler) rather than synchronously inside the effect above — keeps the
  // effect a pure "sync entries with metric" and avoids the extra render
  // that setting state at the top of an effect body would cause.
  function selectTab(next: LeaderboardTab) {
    if (next === tab) return;
    setTab(next);
    if (next !== "syndicates") setEntries(null);
  }

  const podium = entries?.slice(0, 3) ?? [];
  const rest = entries?.slice(3) ?? [];

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label={t("common.back")} className="inline-block text-lg rtl:rotate-180">
          ←
        </button>
        <p className="flex items-center gap-1.5 font-semibold">
          <Trophy className="h-4 w-4 text-amber-400" />
          {t("leaderboard.title")}
        </p>
      </header>

      <div className="flex gap-2 px-4 pt-3">
        {TABS.map(({ tab: tb, labelKey, Icon }) => (
          <button
            key={tb}
            type="button"
            onClick={() => selectTab(tb)}
            className={`flex flex-1 items-center justify-center gap-1.5 rounded-full py-2 text-xs font-semibold transition-colors ${
              tab === tb ? "gradient-action" : "gradient-surface text-nav-inactive"
            }`}
          >
            <Icon className="h-3.5 w-3.5" />
            {t(labelKey)}
          </button>
        ))}
      </div>

      {tab === "syndicates" ? (
        <SyndicateLeaderboardPanel state={state} onStateChange={onStateChange} />
      ) : (
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-8">
          {entries === null && (
            <p className="p-3 text-center text-sm text-nav-inactive">{t("common.loading")}</p>
          )}
          {entries?.length === 0 && (
            <p className="p-3 text-center text-sm text-nav-inactive">{t("leaderboard.empty")}</p>
          )}

          {podium.length > 0 && (
            <div className="flex items-end justify-center gap-4 pt-2">
              {podium[1] && <PodiumSlot entry={podium[1]} rank={2} metric={tab} t={t} />}
              {podium[0] && <PodiumSlot entry={podium[0]} rank={1} metric={tab} t={t} />}
              {podium[2] && <PodiumSlot entry={podium[2]} rank={3} metric={tab} t={t} />}
            </div>
          )}

          {entries && entries.length > 0 && (
            <p className="rounded-xl bg-progress-bg px-3 py-2 text-center text-xs text-nav-inactive">
              {tab === "cycles_launched_total" ? t("leaderboard.subtitleCycles") : t("leaderboard.subtitle")}
            </p>
          )}

          {rest.length > 0 && (
            <div className="gradient-surface flex flex-col divide-y divide-white/5 rounded-xl">
              {rest.map((entry, index) => (
                <div
                  key={`${entry.display_name}-${index}`}
                  className="flex items-center gap-3 p-3 text-sm"
                >
                  <span className="w-5 shrink-0 text-center text-xs text-nav-inactive">{index + 4}</span>
                  <LeaderboardAvatar
                    name={entry.display_name}
                    photoUrl={entry.photo_url}
                    sizeClassName="h-9 w-9"
                    textClassName="text-sm"
                  />
                  <span className="flex-1 truncate">{entry.display_name?.trim() ? entry.display_name.trim() : t("common.playerFallback")}</span>
                  <span className="shrink-0 text-gram">{scoreText(entry, tab, t)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
