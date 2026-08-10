"use client";

import { useEffect, useState } from "react";
import { Building2, Factory, Landmark, Ship, Shield, Swords, Trophy, type LucideIcon } from "lucide-react";
import type { District, GangAvatarId, PlayerState } from "@/lib/types";
import { attackDistrict, fetchDistricts, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { useCountdown, formatDuration, useDurationUnits } from "@/hooks/use-countdown";
import { GangAvatar } from "./gangs-screen";

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
    case "already_controls_district":
      return t("districts.alreadyControls");
    default:
      return t("gangs.actionFailed");
  }
}

/** Live "Xh Ym" / "Xm Ys" countdown to `targetIso`, ticking every second — same building blocks bank-screen.tsx uses for its payout countdown. */
function CountdownLabel({ targetIso }: { targetIso: string }) {
  const seconds = useCountdown(targetIso);
  const units = useDurationUnits();
  return <>{formatDuration(seconds, units)}</>;
}

function TugOfWarBar({ defensePoints, attackPoints }: { defensePoints: number; attackPoints: number }) {
  const total = defensePoints + attackPoints;
  const defenseWidth = total > 0 ? (defensePoints / total) * 100 : 50;
  return (
    <div className="flex h-2 w-full overflow-hidden rounded-full bg-progress-bg">
      <div className="h-full bg-sky-400 transition-all" style={{ width: `${defenseWidth}%` }} />
      <div className="h-full bg-red-400 transition-all" style={{ width: `${100 - defenseWidth}%` }} />
    </div>
  );
}

function CombatantRow({
  icon: Icon,
  label,
  combatant,
  emptyLabel,
  colorClassName,
}: {
  icon: LucideIcon;
  label: string;
  combatant: { name: string; avatar_id: GangAvatarId; points: number } | null;
  emptyLabel: string;
  colorClassName: string;
}) {
  return (
    <div className="flex items-center gap-2 text-xs">
      <Icon className={`h-3.5 w-3.5 shrink-0 ${colorClassName}`} />
      <span className="w-14 shrink-0 text-nav-inactive">{label}</span>
      {combatant ? (
        <>
          <GangAvatar avatarId={combatant.avatar_id} sizeClassName="h-5 w-5" iconClassName="h-3 w-3" />
          <span className="min-w-0 flex-1 truncate">{combatant.name}</span>
          <span className="shrink-0 font-semibold text-gram">{combatant.points}</span>
        </>
      ) : (
        <span className="flex-1 text-nav-inactive">{emptyLabel}</span>
      )}
    </div>
  );
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
  const isActive = district.battle_status === "active";

  const bonusLabel =
    district.bonus_type === "cycle_boost"
      ? t("districts.bonusCycleBoost", { value: district.bonus_value })
      : district.bonus_type === "bank_boost"
        ? t("districts.bonusBankBoost", { value: district.bonus_value })
        : t("districts.bonusSlotDiscount", { value: district.bonus_value });

  const alreadyApplied = district.my_gang_role === "attacker";
  const showAttackButton = canAttack && district.my_gang_role !== "defender";

  return (
    <div
      className={`flex flex-col gap-3 rounded-2xl border p-4 ${
        district.my_gang_role
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

      {isActive ? (
        <div className="flex flex-col gap-1">
          <span className="w-fit rounded-full bg-red-500/15 px-2 py-0.5 text-[10px] font-bold text-red-400">
            {t("districts.battleActive")}
          </span>
          <p className="text-[11px] text-nav-inactive">
            {t("districts.untilBattleEnds")}: <CountdownLabel targetIso={district.next_transition_at} />
          </p>
        </div>
      ) : (
        <p className="text-[11px] text-nav-inactive">
          {t("districts.untilBattleStarts")}: <CountdownLabel targetIso={district.next_transition_at} />
        </p>
      )}

      <TugOfWarBar defensePoints={district.defender?.points ?? 0} attackPoints={district.top_challenger?.points ?? 0} />

      <div className="flex flex-col gap-1.5 rounded-xl bg-progress-bg p-2.5">
        <CombatantRow
          icon={Shield}
          label={t("districts.defenderLabel")}
          combatant={district.defender}
          emptyLabel={t("districts.unclaimed")}
          colorClassName="text-sky-400"
        />
        <CombatantRow
          icon={Swords}
          label={t("districts.attackerLabel")}
          combatant={district.top_challenger}
          emptyLabel={t("districts.noChallenger")}
          colorClassName="text-red-400"
        />
      </div>

      {district.my_gang_role === "defender" && (
        <p className="rounded-xl bg-sky-500/10 p-2.5 text-[11px] text-sky-300">{t("districts.defendingBanner")}</p>
      )}

      {showAttackButton && (
        <button
          type="button"
          onClick={() => onAttack(district.id)}
          disabled={alreadyApplied || attacking}
          className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-2.5 text-xs font-semibold disabled:opacity-40"
        >
          <Swords className="h-3.5 w-3.5 shrink-0" />
          {alreadyApplied ? t("districts.applied") : attacking ? t("districts.attacking") : t("districts.requestAttack")}
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
