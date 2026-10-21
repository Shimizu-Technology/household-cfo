// Plain-language helpers for participant savings screens.
//
// Glossary (participant-facing words; keep these consistent across the savings
// challenge home, joining, paused, evidence, snapshot, debt and export screens):
//   reported savings / reserve        -> "set aside"
//   supported / backed by statements  -> "matched to a statement"
//                                        (a match is included in what you set aside, never added to it)
//   baseline                          -> "spending snapshot"
//   checkpoint                        -> "Day 30 check-in" (Day 60, Day 90)
//   approve (your own records)        -> "Save" or "Confirm"
//   not counted / excluded            -> say why in words when it matters; hide when the count is zero
//   unknown                           -> words such as "No amounts added yet", never $0; a confirmed zero shows $0.00 with its date
//   time zone                         -> mention once ("Dates follow Guam time"), not on every card
//
// Date-only strings ("2026-10-17") are calendar days, not instants. They are
// formatted in UTC so a participant's device time zone can never shift the day.

const DAY = /^(\d{4})-(\d{2})-(\d{2})$/

function dayDate(iso: string): Date | null {
  const match = DAY.exec(iso)
  if (!match) return null
  const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])))
  return date.toISOString().slice(0, 10) === iso ? date : null
}

const withoutYear = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' })
const withYear = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })

// formatDay('2026-10-17') -> 'Sat, Oct 17'; with { year: true } -> 'Sat, Oct 17, 2026'.
// Anything that is not a real calendar day is returned unchanged.
export function formatDay(iso: string | null | undefined, options: { year?: boolean } = {}): string {
  if (!iso) return ''
  const date = dayDate(iso)
  if (!date) return iso
  return (options.year ? withYear : withoutYear).format(date)
}

// Approval timestamps are instants. Resolve their calendar day in Guam before
// passing it to formatDay; date-only fields above must never be shifted.
export function formatGuamTimestamp(value: string, options: { year?: boolean } = {}): string {
  const instant = new Date(value)
  if (!Number.isFinite(instant.getTime())) return 'Date unavailable'
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(instant)
  const part = (type: string) => parts.find(row => row.type === type)?.value ?? ''
  return formatDay(`${part('year')}-${part('month')}-${part('day')}`, options)
}

// formatRange('2026-10-17', '2027-01-14') -> 'Sat, Oct 17 – Thu, Jan 14, 2027'.
// The end year identifies every financial period, including same-year ranges.
export function formatRange(start: string | null | undefined, end: string | null | undefined): string {
  if (!start || !end) return [formatDay(start, { year: true }), formatDay(end, { year: true })].filter(Boolean).join(' – ')
  return `${formatDay(start)} – ${formatDay(end, { year: true })}`
}

// 'Pacific/Guam' -> 'Guam time'; 'America/Los_Angeles' -> 'Los Angeles time'.
export function timeZoneLabel(zone: string | null | undefined): string {
  if (!zone) return ''
  const place = zone.split('/').pop()!.replaceAll('_', ' ')
  return `${place} time`
}
