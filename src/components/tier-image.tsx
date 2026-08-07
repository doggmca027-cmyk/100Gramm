import Image from "next/image";
import { TIER_ACCENT, TIER_ICON, TIER_IMAGE_URL, DEFAULT_TIER_ICON } from "@/lib/tier-art";

export function TierImage({
  tier,
  className,
  iconClassName = "h-8 w-8",
}: {
  tier: number;
  className: string;
  iconClassName?: string;
}) {
  const url = TIER_IMAGE_URL[tier];
  const accent = TIER_ACCENT[tier] ?? "#8b7765";
  const Icon = TIER_ICON[tier] ?? DEFAULT_TIER_ICON;

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
      <Icon className={`${iconClassName} text-amber-400`} strokeWidth={1.75} />
    </div>
  );
}
