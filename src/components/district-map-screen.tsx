"use client";

import { useEffect, useState } from "react";
import { Building2, Factory, Landmark, Ship, Swords, Trophy, type LucideIcon } from "lucide-react";
import type { District, PlayerState } from "@/lib/types";
import { attackDistrict, fetchDistricts, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { GANG_AVATARS, GangAvatar } from "./gangs-screen";

/** slug -> icon. The districts table itself has no icon column (see 0063_district_wars.sql's header) — same "server stores an id, client maps it to an art asset" split gang-avatars.ts uses for emblems. Falls back to Landmark for any future district slug that isn't listed here. */
const DISTRICT_ICONS: Record<string, LucideIcon> = {
  "central-bank": Landmark,
  port: Ship,
  "industrial-zone": Factory,
  "old-town": Building2,
};

function districtErrorMessage(err: unknown, t: ReturnType<typeof useLanguage>["t"]): string {
  const code = err instanceof ApiError ? err.code : null;
  switch (code) {
    case "not_in_gang":
      return t("districts.notInGang");
    case "not_gang_officer":
      return t("districts.notOfficer");
    default:
      return t("gangs.actionFailed");
  }
}

function DistrictCard({
  district,
  canAttack,
  attacking,
  onAttack,
}: {
  district: District;
  canAttack: boolean;
  attacking: boolean;
  onAttack: (id: string) => void;
}) {
  const { t } = useLanguage();
  const Icon = DISTRICT_ICONS[district.slug] ?? Landmark;

  const bonusLabel =
    district.bonus_type === "cycle_boost"
      ? t("districts.bonusCycleBoost", { value: district.bonus_value })
      : district.bonus_type === "bank_boost"
        ? t("districts.bonusBankBoost", { value: district.bonus_value })
        : t("districts.bonusSlotDiscount", { value: district.bonus_value });

  return (
    <div
      className={`flex flex-col gap-3 rounded-2xl border p-4 ${
        district.is_my_target
          ? "border-amber-500/50 bg-amber-500/10 shadow-[0_0_18px_rgba(245,158,11,0.14)]"
          : "border-purple-900/40 bg-slate-900/80"
      }`}
    >
      <div className="flex items-center gap-3">
        <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-purple-900/40 bg-progress-bg">
          <Icon className="h-5 w-5 text-amber-400" />
        </div>
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-semibold">{district.name}</p>
          <p className="text-xs text-gram">{bonusLabel}</p>
        </div>
      </div>

      <div className="flex items-center gap-2 rounded-xl bg-progress-bg p-2.5 text-xs">
        {district.controlling_gang ? (
          <>
            <GangAvatar avatarId={district.controlling_gang.avatar_id} sizeClassName="h-7 w-7" iconClassName="h-3.5 w-3.5" />
            <div className="min-w-0 flex-1">
              <p className="text-[10px] text-nav-inactive">{t("districts.controlledBy")}</p>
              <p className="truncate font-semibold">{district.controlling_gang.name}</p>
            </div>
          </>
        ) : (
          <p className="text-nav-inactive">{t("districts.unclaimed")}</p>
        )}
      </div>

      {district.top_influence.length > 0 && (
        <div className="flex flex-col gap-1">
          <p className="flex items-center gap-1 text-[11px] text-nav-inactive">
            <Trophy className="h-3 w-3 shrink-0 text-amber-400" />
            {t("districts.topInfluence")}
          </p>
          {district.top_influence.map((entry, i) => {
            const { Icon: AvatarIcon, className } = GANG_AVATARS[entry.avatar_id] ?? GANG_AVATARS.default_gang;
            return (
              <div key={entry.gang_id} className="flex items-center justify-between text-xs">
                <span className="flex min-w-0 items-center gap-1.5">
                  <span className="text-nav-inactive">{i + 1}.</span>
                  <AvatarIcon className={`h-3.5 w-3.5 shrink-0 ${className}`} />
                  <span className="truncate">{entry.name}</span>
                </span>
                <span className="shrink-0 font-semibold text-gram">{entry.points}</span>
              </div>
            );
          })}
        </div>
      )}

      {district.my_gang_points !== null && (
        <p className="text-[11px] text-nav-inactive">
          {t("districts.myGangPoints", { points: district.my_gang_points })}
        </p>
      )}

      {canAttack && (
        <button
          type="button"
          onClick={() => onAttack(district.id)}
          disabled={district.is_my_target || attacking}
          className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-2.5 text-xs font-semibold disabled:opacity-40"
        >
          <Swords className="h-3.5 w-3.5 shrink-0" />
          {district.is_my_target ? t("districts.currentTarget") : attacking ? t("districts.attacking") : t("districts.attack")}
        </button>
      )}
    </div>
  );
}

export function DistrictMapScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [districts, setDistricts] = useState<District[] | null>(null);
  const [attackingId, setAttackingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  function load() {
    fetchDistricts()
      .then(setDistricts)
      .catch(() => setDistricts([]));
  }

  useEffect(() => {
    load();
  }, []);

  const canAttack = state.gang?.my_role === "leader" || state.gang?.my_role === "co_leader";

  async function handleAttack(districtId: string) {
    setAttackingId(districtId);
    setError(null);
    try {
      const { state: next } = await attackDistrict(districtId);
      onStateChange(next);
      load();
    } catch (err) {
      setError(districtErrorMessage(err, t));
    } finally {
      setAttackingId(null);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface flex flex-col items-center gap-1 rounded-2xl border border-purple-900/40 p-4 text-center">
        <Trophy className="h-6 w-6 text-amber-400" />
        <h1 className="text-base font-bold">{t("districts.title")}</h1>
        <p className="text-xs text-nav-inactive">{t("districts.subtitle")}</p>
      </div>

      {error && <p className="text-center text-xs text-danger">{error}</p>}

      {districts === null && <p className="p-3 text-center text-sm text-nav-inactive">{t("common.loading")}</p>}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        {districts?.map((d) => (
          <DistrictCard
            key={d.id}
            district={d}
            canAttack={Boolean(canAttack)}
            attacking={attackingId === d.id}
            onAttack={handleAttack}
          />
        ))}
      </div>
    </div>
  );
}
