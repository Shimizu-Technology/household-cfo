export type MiaManualPayload = Record<string, unknown>

export function payloadHas(payload: MiaManualPayload, key: string) {
  return Object.prototype.hasOwnProperty.call(payload, key)
}

export function proposedText(payload: MiaManualPayload, key: string, fallback: string) {
  if (!payloadHas(payload, key)) return fallback
  const value = payload[key]
  return value === null || value === undefined ? '' : String(value)
}

export function proposedMoney(
  payload: MiaManualPayload,
  centsKey: string,
  fallback: string,
  knownKey?: string,
) {
  if (knownKey && payloadHas(payload, knownKey) && payload[knownKey] === false) return ''
  if (!payloadHas(payload, centsKey)) return fallback
  if (payload[centsKey] === null || payload[centsKey] === undefined) return ''
  const cents = Number(payload[centsKey])
  return Number.isFinite(cents) ? String(cents / 100) : fallback
}

export function proposedChoice<T extends string>(
  payload: MiaManualPayload,
  key: string,
  fallback: T,
  choices: readonly T[],
) {
  const value = payload[key]
  return payloadHas(payload, key) && choices.includes(value as T) ? value as T : fallback
}

export function proposedBoolean(payload: MiaManualPayload, key: string, fallback: boolean) {
  return payloadHas(payload, key) && typeof payload[key] === 'boolean' ? payload[key] : fallback
}

export function budgetMonthsFromPayload(payload: MiaManualPayload) {
  const candidates = Array.isArray(payload.months)
    ? payload.months
    : Array.isArray(payload.month_numbers)
      ? payload.month_numbers
      : Array.isArray(payload.changes)
        ? payload.changes.map((change) => change && typeof change === 'object' ? (change as MiaManualPayload).month : null)
        : []

  return [...new Set(candidates.map(Number).filter((month) => Number.isInteger(month) && month >= 1 && month <= 12))]
}
