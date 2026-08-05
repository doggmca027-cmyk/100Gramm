"use client";

import { useEffect, useState } from "react";
import { fetchLeaderboard, type LeaderboardEntry } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

const RANK_BADGE_CLASS: Record<number, string> = {
  1: "bg-gram text-bg",
  2: "bg-[#c9ccd6] text-bg",
  3: "bg-[#cd8a4f] text-bg",
};

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

function PodiumSlot({ entry, rank, t }: { entry: LeaderboardEntry; rank: 1 | 2 | 3; t: ReturnType<typeof useLanguage>["t"] }) {
  const isFirst = rank === 1;

  return (
    <div className={`flex flex-col items-center gap-1 ${isFirst ? "" : "pb-3"}`}>
      {isFirst && <span className="text-xl leading-none">👑</span>}
      <div className="relative">
        <LeaderboardAvatar
          name={entry.display_name}
          photoUrl={entry.photo_url}
          sizeClassName={isFirst ? "h-20 w-20" : "h-16 w-16"}
          textClassName={isFirst ? "text-2xl" : "text-xl"}
        />
        <span
          className={`absolute -bottom-1 -right-1 flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ring-2 ring-bg ${RANK_BADGE_CLASS[rank]}`}
        >
          {rank}
        </span>
      </div>
      <p className={`max-w-[84px] truncate text-center font-semibold ${isFirst ? "text-sm" : "text-xs"}`}>
        {entry.display_name}
      </p>
      <p className="text-xs text-gram">
        {entry.total_earned.toFixed(0)} {t("common.gram")}
      </p>
    </div>
  );
}

export function LeaderboardScreen({ onBack }: { onBack: () => void }) {
  const { t } = useLanguage();
  const [entries, setEntries] = useState<LeaderboardEntry[] | null>(null);

  useEffect(() => {
    fetchLeaderboard("total_earned")
      .then(setEntries)
      .catch(() => setEntries([]));
  }, []);

  const podium = entries?.slice(0, 3) ?? [];
  const rest = entries?.slice(3) ?? [];

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label={t("common.back")} className="text-lg">
          ←
        </button>
        <p className="font-semibold">{t("leaderboard.title")}</p>
      </header>

      <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-8">
        {entries === null && (
          <p className="p-3 text-center text-sm text-nav-inactive">{t("common.loading")}</p>
        )}
        {entries?.length === 0 && (
          <p className="p-3 text-center text-sm text-nav-inactive">{t("leaderboard.empty")}</p>
        )}

        {podium.length > 0 && (
          <div className="flex items-end justify-center gap-4 pt-2">
            {podium[1] && <PodiumSlot entry={podium[1]} rank={2} t={t} />}
            {podium[0] && <PodiumSlot entry={podium[0]} rank={1} t={t} />}
            {podium[2] && <PodiumSlot entry={podium[2]} rank={3} t={t} />}
          </div>
        )}

        {entries && entries.length > 0 && (
          <p className="rounded-xl bg-progress-bg px-3 py-2 text-center text-xs text-nav-inactive">
            {t("leaderboard.subtitle")}
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
                <span className="flex-1 truncate">{entry.display_name}</span>
                <span className="shrink-0 text-gram">
                  {entry.total_earned.toFixed(2)} {t("common.gram")}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
