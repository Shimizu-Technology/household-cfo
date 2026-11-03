export function guamTodayIso(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(date)
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${value.year}-${value.month}-${value.day}`
}

/** Calendar dates stay on their stated day, including on devices outside Guam. */
export function formatHouseholdDay(value: string, today = new Date()) {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'UTC', month: 'short', day: 'numeric',
    year: value.slice(0, 4) === guamTodayIso(today).slice(0, 4) ? undefined : 'numeric',
  }).format(new Date(`${value}T00:00:00Z`))
}

export function formatHouseholdMonth(value: string, today = new Date()) {
  const [year, month] = value.split('-').map(Number)
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'UTC', month: 'short',
    year: year === Number(guamTodayIso(today).slice(0, 4)) ? undefined : 'numeric',
  }).format(new Date(Date.UTC(year, month - 1, 1)))
}
