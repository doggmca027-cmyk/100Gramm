import type { BankPlanDays } from "./types";

/**
 * Client-side mirror of create_bank_deposit's plan table
 * (0056_bank_staking.sql) — for the UI only: disabling the submit button
 * early, showing the red-border/hint state, populating the quick-select
 * amounts. The server re-validates every one of these numbers itself and
 * never trusts anything the client sends; this list drifting from the SQL
 * would only ever produce a confusing UI, never a security or balance bug.
 *
 * The 14-day plan's bonus is genuinely conditional server-side (grants
 * +1 slot if the player already has at least one open slot at deposit
 * time, otherwise +10% speed) — grantsSpeed/grantsSlot here both stay
 * `false` for it since neither is guaranteed; the UI shows both possible
 * outcomes in the card copy instead of picking one.
 */
export interface BankPlan {
  days: BankPlanDays;
  yieldPercent: number;
  minAmount: number;
  grantsSpeed: boolean;
  grantsSlot: boolean;
  /** i18n key for the full sentence spelling out this plan's buff — shown under the card, not just the icon badges. */
  perkDescriptionKey: `bank.perk${string}`;
}

export const BANK_PLANS: BankPlan[] = [
  { days: 7, yieldPercent: 5, minAmount: 3, grantsSpeed: true, grantsSlot: false, perkDescriptionKey: "bank.perk7" },
  { days: 14, yieldPercent: 12, minAmount: 10, grantsSpeed: false, grantsSlot: false, perkDescriptionKey: "bank.perk14" },
  { days: 30, yieldPercent: 30, minAmount: 15, grantsSpeed: true, grantsSlot: true, perkDescriptionKey: "bank.perk30" },
];

export function bankPlan(days: BankPlanDays): BankPlan {
  return BANK_PLANS.find((p) => p.days === days)!;
}
