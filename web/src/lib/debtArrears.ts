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
