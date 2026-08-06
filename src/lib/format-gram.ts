/**
 * Formats a GRAM amount for display: 2 decimals normally (matching every
 * other GRAM figure in the app), but falls back to up to 4 decimals —
 * trailing zeros trimmed — when 2 decimals would lose the value entirely.
 * Needed for sub-cent rewards like a 0.003 GRAM partner task, which would
 * otherwise silently render as "0.00".
 */
export function formatGramAmount(amount: number): string {
  const rounded2 = Math.round(amount * 100) / 100;
  if (Math.abs(rounded2 - amount) < 1e-9) {
    return amount.toFixed(2);
  }
  return amount.toFixed(4).replace(/0+$/, "").replace(/\.$/, "");
}
