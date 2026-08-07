"use client";

import { useState } from "react";
import { UserRound } from "lucide-react";
import { rankRingGradient } from "@/lib/rank-art";

/**
 * Telegram profile photo with a ring colored by rank/progress. Falls back to
 * the rank emoji (on the usual purple gradient) whenever there's no photo —
 * either Telegram never gave us one, or it failed to load.
 */
export function ProfileAvatar({
  photoUrl,
  rankIcon,
  rankLevel,
  sizeClassName = "h-14 w-14",
  emojiClassName = "text-2xl",
  className = "",
}: {
  photoUrl: string | null;
  rankIcon: string | null;
  rankLevel: number | undefined;
  sizeClassName?: string;
  emojiClassName?: string;
  /** Extra classes on the outer ring wrapper — e.g. a decorative ring-* accent layered on top of the rank-colored gradient ring. */
  className?: string;
}) {
  const [failed, setFailed] = useState(false);
  const showPhoto = photoUrl && !failed;

  return (
    <div
      className={`${sizeClassName} shrink-0 rounded-full p-[2px] ${className}`}
      style={{ backgroundImage: rankRingGradient(rankLevel) }}
    >
      <div className="h-full w-full overflow-hidden rounded-full bg-bg">
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
          <div className="gradient-action flex h-full w-full items-center justify-center">
            {rankIcon ? (
              <span className={emojiClassName}>{rankIcon}</span>
            ) : (
              <UserRound className="h-1/2 w-1/2 text-white/90" strokeWidth={1.75} />
            )}
          </div>
        )}
      </div>
    </div>
  );
}
