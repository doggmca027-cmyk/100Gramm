import type { LucideIcon } from "lucide-react";

export function ComingSoonSection({
  icon: Icon,
  title,
  description,
}: {
  icon: LucideIcon;
  title: string;
  description: string;
}) {
  return (
    <div className="flex flex-col gap-2">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Icon className="h-4 w-4 text-neutral-400" />
        {title}
      </h2>
      <div className="gradient-surface rounded-xl p-4 text-center text-xs text-nav-inactive">
        {description}
      </div>
    </div>
  );
}
