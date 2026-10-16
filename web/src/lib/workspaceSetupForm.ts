import type { WorkspaceSetupValues } from '../api'

// Same household ceiling the API enforces for every participant money input.
export const MAX_MONEY_AMOUNT = 9_999_999.99
export const MAX_MONEY_AMOUNT_TEXT = '$9,999,999.99'

/**
 * Only the fields the person actually changed since the form was loaded.
 * Saving an untouched aggregate (for example Flexible spending when it is
 * split across several categories with one-month overrides) would otherwise
 * ask the API to flatten detailed monthly amounts the person never edited.
 */
export function changedWorkspaceSetupValues(
  current: Partial<WorkspaceSetupValues>,
  baseline: Partial<WorkspaceSetupValues>,
): Partial<WorkspaceSetupValues> {
  return Object.fromEntries(Object.entries(current).filter(([key, value]) => (
    !sameSetupValue(value, baseline[key as keyof WorkspaceSetupValues])
  ))) as Partial<WorkspaceSetupValues>
}

function sameSetupValue(left: unknown, right: unknown) {
  if (typeof left === 'string' || typeof right === 'string') {
    return String(left ?? '').replace(/\s+/g, ' ').trim() === String(right ?? '').replace(/\s+/g, ' ').trim()
  }
  if (left === null || left === undefined || right === null || right === undefined) return left === right
  // Sub-cent differences (a typed 0.001 against a $0 baseline) are real edits:
  // keep them so the money check can report them instead of silently dropping them.
  return Math.abs(Number(left) - Number(right)) < 1e-6
}

/**
 * Plain-language check for a typed money amount. Blank is allowed (the form
 * saves it as $0, or as unknown for optional balances). Returns null when the
 * text is acceptable.
 */
export function moneyInputProblem(label: string, text: string): string | null {
  const value = text.trim()
  if (value === '') return null
  if (!/^\d+(\.\d+)?$/.test(value)) return `${label}: enter a dollar amount using numbers only, like 1250 or 1250.50.`
  if (!/^\d+(\.\d{1,2})?$/.test(value)) return `${label}: use no more than two decimal places (cents), like 1250.50.`
  if (Number(value) > MAX_MONEY_AMOUNT) return `${label} must be ${MAX_MONEY_AMOUNT_TEXT} or less.`
  return null
}
