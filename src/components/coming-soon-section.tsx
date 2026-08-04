export function ComingSoonSection({
  icon,
  title,
  description,
}: {
  icon: string;
  title: string;
  description: string;
}) {
  return (
    <div className="flex flex-col gap-2">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">
        {icon} {title}
      </h2>
      <div className="gradient-surface rounded-xl p-4 text-center text-xs text-nav-inactive">
        {description}
      </div>
    </div>
  );
}
