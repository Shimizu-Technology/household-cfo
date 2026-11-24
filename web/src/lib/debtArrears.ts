/** "1st", "2nd", "15th", "22nd": a due day as people say it. */
export function ordinalDay(day: number) {
  const tens = day % 100
  if (tens >= 11 && tens <= 13) return `${day}th`
  return `${day}${({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[day % 10] ?? 'th'}`
}

/** A blank field stays unknown (null); only a typed amount, including 0, is saved. */
export function parseOptionalAmount(text: string): number | null | 'invalid' {
  if (text.trim() === '') return null
  const value = Number(text)
  return Number.isFinite(value) && value >= 0 ? value : 'invalid'
}

export function parseDueDay(text: string): number | null | 'invalid' {
  if (text.trim() === '') return null
  const value = Number(text)
  return Number.isInteger(value) && value >= 1 && value <= 31 ? value : 'invalid'
}

/**
 * The fields she changed on a debt form, and what the form showed for each before she
 * changed it. Only these are sent, with `expected` holding the old values, so an older
 * tab never overwrites a past-due amount or due day saved since (from Mia or another
 * device): an unchanged field is not sent, and a changed one is refused if it moved.
 */
export function changedDebtFields<T extends Record<string, unknown>>(values: T, baseline: T): { changes: Partial<T>; expected: Partial<T> } {
  const changes: Partial<T> = {}
  const expected: Partial<T> = {}
  for (const key of Object.keys(values) as Array<keyof T>) {
    if (Object.is(values[key], baseline[key])) continue
    changes[key] = values[key]
    expected[key] = baseline[key]
  }
  return { changes, expected }
}

/** "Caught up" for an explicit $0, the amount when behind, nothing when not entered. */
export function pastDueStatus(pastDue: number | null | undefined): 'caught_up' | 'behind' | null {
  if (pastDue == null) return null
  return pastDue > 0 ? 'behind' : 'caught_up'
}
