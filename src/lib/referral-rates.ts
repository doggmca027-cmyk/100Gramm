/**
 * Standard vs ambassador referral rates — must match start_cycle() in
 * supabase/migrations exactly (currently 0034_referral_rate_update.sql).
 * Display-only: the actual payout always comes from the database. Shared
 * between squad-screen.tsx and balance-screen.tsx so there's exactly one
 * place to update when the rates change, not two copies that can drift
 * out of sync with each other (as happened before this file existed).
 */
export const REFERRAL_RATES = {
  standard: [5, 3, 1],
  ambassador: [8, 5, 3],
} as const;
