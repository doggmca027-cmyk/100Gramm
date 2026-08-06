/**
 * Minimum deposit amount, shared by every funding path — TON Connect,
 * manual TON, TON Connect USDT, and manual USDT. GRAM-denominated; USDT
 * paths convert it via the live GRAM/USDT rate at the point they check it
 * (see usdt-payment/prepare/route.ts and lib/usdt-deposit-sweep.ts), so
 * this single number is the one source of truth for "0.5 GRAM или по
 * курсу в USDT" instead of six independent copies of the same constant.
 */
export const MIN_DEPOSIT_GRAM = 0.5;
