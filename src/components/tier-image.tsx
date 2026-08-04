import Image from "next/image";
import { TIER_ACCENT, TIER_ICON, TIER_IMAGE_URL } from "@/lib/tier-art";

export function TierImage({
  tier,
  className,
  emojiClassName = "text-3xl",
}: {
  tier: number;
  className: string;
  emojiClassName?: string;
}) {
  const url = TIER_IMAGE_URL[tier];
  const accent = TIER_ACCENT[tier] ?? "#8b7765";

  if (url) {
    return (
      <Image
        src={url}
        alt=""
        width={200}
        height={200}
        className={`${className} object-cover`}
      />
    );
  }

  return (
    <div
      className={`${className} flex items-center justify-center`}
      style={{ backgroundImage: `linear-gradient(160deg, ${accent}55, ${accent}15)` }}
    >
      <span className={emojiClassName}>{TIER_ICON[tier] ?? "🍾"}</span>
    </div>
  );
}
