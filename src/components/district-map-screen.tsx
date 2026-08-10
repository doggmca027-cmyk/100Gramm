"use client";

import { useEffect, useState } from "react";
import {
  Building2,
  Factory,
  Landmark,
  Ship,
  Shield,
  ShieldCheck,
  Swords,
  Trophy,
  Rocket,
  Bot,
  type LucideIcon,
} from "lucide-react";
import type { District, DistrictBoostType, DistrictCombatant, PlayerState } from "@/lib/types";
import { attackDistrict, activateDistrictBoost, activateMercenaryBot, fetchDistricts, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { useCountdown, formatDuration, useDurationUnits } from "@/hooks/use-countdown";
import {
  AIRSTRIKE_2X_COST,
  AIRSTRIKE_3X_COST,
  ENGINEER_SHIELD_COST,
  MERCENARY_BOT_COST,
} from "@/lib/gang-avatars";
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
    case "battle_not_active":
      return t("districts.battleNotActive");
    case "boost_already_active":
      return t("districts.boostAlreadyActive");
    case "not_district_defender":
      return t("districts.notDefender");
    case "mercenary_already_active":
      return t("districts.mercenaryAlreadyActive");
    case "insufficient_balance":
      return t("gangs.insufficientBalance");
    case "insufficient_gang_bank":
      return t("gangs.insufficientGangBank");
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
  combatant: DistrictCombatant | null;
  emptyLabel: string;
  colorClassName: string;
}) {
  return (
    <div className="flex items-center gap-2 text-xs">
      <Icon className={`h-3.5 w-3.5 shrink-0 ${colorClassName}`} />
      <span className="w-14 shrink-0 text-nav-inactive">{label}</span>
      {combatant ? (
        <>
          <GangAvatar avatarId={combatant.avatar_id} cosmetics={combatant} sizeClassName="h-5 w-5" iconClassName="h-3 w-3" />
          <span className="min-w-0 flex-1 truncate">{combatant.name}</span>
          <span className="shrink-0 font-semibold text-gram">{combatant.points}</span>
        </>
      ) : (
        <span className="flex-1 text-nav-inactive">{emptyLabel}</span>
      )}
    </div>
  );
}

/** "🚀 АВИАУДАР 3X АКТИВЕН (Осталось: 1h 45m)" / "🛡 ЩИТ РАЙОНА АКТИВЕН (...)" style badge for one active boost. */
function BoostBadge({ boostType, gangName, expiresAt }: { boostType: DistrictBoostType; gangName: string; expiresAt: string }) {
  const { t } = useLanguage();
  const isShield = boostType === "engineer_shield";
  const label = isShield
    ? t("districts.shieldActive")
    : t("districts.airstrikeActive", { multiplier: boostType === "airstrike_3x" ? 3 : 2 });

  return (
    <div className={`flex items-center gap-1.5 rounded-lg px-2 py-1 text-[10px] font-semibold ${isShield ? "bg-sky-500/15 text-sky-300" : "bg-red-500/15 text-red-300"}`}>
      {isShield ? <ShieldCheck className="h-3 w-3 shrink-0" /> : <Rocket className="h-3 w-3 shrink-0" />}
      <span className="truncate">
        {gangName}: {label}
      </span>
      <span className="shrink-0 text-nav-inactive">
        (<CountdownLabel targetIso={expiresAt} />)
      </span>
    </div>
  );
}

function DistrictCard({
  district,
  canManage,
  busyKey,
  payFromBank,
  onTogglePayFromBank,
  onAttack,
  onBoost,
  onMercenary,
}: {
  district: District;
  canManage: boolean;
  busyKey: string | null;
  payFromBank: boolean;
  onTogglePayFromBank: () => void;
  onAttack: (id: string) => void;
  onBoost: (id: string, boostType: DistrictBoostType) => void;
  onMercenary: (id: string) => void;
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
  const showAttackButton = canManage && district.my_gang_role !== "defender";
  const showBoostPanel = canManage && isActive && district.my_gang_role !== null;
  const isAttacking = busyKey === `${district.id}:attack`;
  const isHiringMercenary = busyKey === `${district.id}:mercenary`;

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

      {(district.active_boosts.length > 0 || district.mercenary_bots.length > 0) && (
        <div className="flex flex-col gap-1">
          {district.active_boosts.map((b, i) => (
            <BoostBadge key={i} boostType={b.boost_type} gangName={b.gang_name} expiresAt={b.expires_at} />
          ))}
          {district.mercenary_bots.map((m, i) => (
            <div key={i} className="flex items-center gap-1.5 rounded-lg bg-purple-500/15 px-2 py-1 text-[10px] font-semibold text-purple-300">
              <Bot className="h-3 w-3 shrink-0" />
              <span className="truncate">
                {m.gang_name}: {t("districts.mercenaryActive")}
              </span>
              <span className="shrink-0 text-nav-inactive">
                (<CountdownLabel targetIso={m.expires_at} />)
              </span>
            </div>
          ))}
        </div>
      )}

      {district.my_gang_role === "defender" && (
        <p className="rounded-xl bg-sky-500/10 p-2.5 text-[11px] text-sky-300">{t("districts.defendingBanner")}</p>
      )}

      {showBoostPanel && (
        <div className="flex flex-col gap-2 rounded-xl border border-purple-900/40 bg-black/20 p-2.5">
          <label className="flex items-center gap-1.5 text-[11px] text-nav-inactive">
            <input type="checkbox" checked={payFromBank} onChange={onTogglePayFromBank} className="accent-amber-400" />
            {t("districts.payFromBank")}
          </label>
          <div className="grid grid-cols-2 gap-1.5">
            <button
              type="button"
              onClick={() => onBoost(district.id, "airstrike_2x")}
              disabled={busyKey === `${district.id}:airstrike_2x`}
              className="flex items-center justify-center gap-1 rounded-full bg-progress-bg py-2 text-[10px] font-semibold text-red-300 disabled:opacity-40"
            >
              <Rocket className="h-3 w-3 shrink-0" />
              {t("districts.buyAirstrike2x", { cost: AIRSTRIKE_2X_COST })}
            </button>
            <button
              type="button"
              onClick={() => onBoost(district.id, "airstrike_3x")}
              disabled={busyKey === `${district.id}:airstrike_3x`}
              className="flex items-center justify-center gap-1 rounded-full bg-progress-bg py-2 text-[10px] font-semibold text-red-300 disabled:opacity-40"
            >
              <Rocket className="h-3 w-3 shrink-0" />
              {t("districts.buyAirstrike3x", { cost: AIRSTRIKE_3X_COST })}
            </button>
            {district.my_gang_role === "defender" && (
              <button
                type="button"
                onClick={() => onBoost(district.id, "engineer_shield")}
                disabled={busyKey === `${district.id}:engineer_shield`}
                className="col-span-2 flex items-center justify-center gap-1 rounded-full bg-progress-bg py-2 text-[10px] font-semibold text-sky-300 disabled:opacity-40"
              >
                <ShieldCheck className="h-3 w-3 shrink-0" />
                {t("districts.buyShield", { cost: ENGINEER_SHIELD_COST })}
              </button>
            )}
            <button
              type="button"
              onClick={() => onMercenary(district.id)}
              disabled={isHiringMercenary}
              className="col-span-2 flex items-center justify-center gap-1 rounded-full bg-progress-bg py-2 text-[10px] font-semibold text-purple-300 disabled:opacity-40"
            >
              <Bot className="h-3 w-3 shrink-0" />
              {isHiringMercenary ? t("gangs.buying") : t("districts.hireMercenary", { cost: MERCENARY_BOT_COST })}
            </button>
          </div>
        </div>
      )}

      {showAttackButton && (
        <button
          type="button"
          onClick={() => onAttack(district.id)}
          disabled={alreadyApplied || isAttacking}
          className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-2.5 text-xs font-semibold disabled:opacity-40"
        >
          <Swords className="h-3.5 w-3.5 shrink-0" />
          {alreadyApplied ? t("districts.applied") : isAttacking ? t("districts.attacking") : t("districts.requestAttack")}
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
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const [payFromBank, setPayFromBank] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function load() {
    fetchDistricts()
      .then(setDistricts)
      .catch(() => setDistricts([]));
  }

  useEffect(() => {
    load();
  }, []);

  const canManage = state.gang?.my_role === "leader" || state.gang?.my_role === "co_leader";

  async function handleAttack(districtId: string) {
    setBusyKey(`${districtId}:attack`);
    setError(null);
    try {
      const { state: next } = await attackDistrict(districtId);
      onStateChange(next);
      load();
    } catch (err) {
      setError(districtErrorMessage(err, t));
    } finally {
      setBusyKey(null);
    }
  }

  async function handleBoost(districtId: string, boostType: DistrictBoostType) {
    setBusyKey(`${districtId}:${boostType}`);
    setError(null);
    try {
      const { state: next } = await activateDistrictBoost(districtId, boostType, payFromBank);
      onStateChange(next);
      load();
    } catch (err) {
      setError(districtErrorMessage(err, t));
    } finally {
      setBusyKey(null);
    }
  }

  async function handleMercenary(districtId: string) {
    setBusyKey(`${districtId}:mercenary`);
    setError(null);
    try {
      const { state: next } = await activateMercenaryBot(districtId, payFromBank);
      onStateChange(next);
      load();
    } catch (err) {
      setError(districtErrorMessage(err, t));
    } finally {
      setBusyKey(null);
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
            canManage={Boolean(canManage)}
            busyKey={busyKey}
            payFromBank={payFromBank}
            onTogglePayFromBank={() => setPayFromBank((v) => !v)}
            onAttack={handleAttack}
            onBoost={handleBoost}
            onMercenary={handleMercenary}
          />
        ))}
      </div>
    </div>
  );
}
