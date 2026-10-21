import { savingsDollars, type SavingsIntake } from '../lib/savingsChallenge'

// "Today", "Yesterday", or "Mon, Oct 20".
function plainDay(iso: string, today?: string): string {
  if (today && iso === today) return 'Today'
  if (today) {
    const yesterday = new Date(`${today}T00:00:00Z`)
    yesterday.setUTCDate(yesterday.getUTCDate() - 1)
    if (iso === yesterday.toISOString().slice(0, 10)) return 'Yesterday'
  }
  return new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(`${iso}T00:00:00Z`))
}

export function MiaSavingsReview({intake,today,onReview}:{intake:SavingsIntake;today?:string;onReview:()=>void}) {
  const amount = savingsDollars(intake.amount_cents)
  const title = intake.kind==='purchase' ? `${amount} at ${intake.merchant}` : intake.kind==='withdrawal' ? `${amount} taken out` : `${amount} set aside`
  return <section className="daily-note" aria-label="Savings to check"><strong>{title} · {plainDay(intake.effective_on, today)}</strong><p>{intake.kind==='purchase' ? 'Check it, then save it in Today. Nothing is saved until you do.' : intake.kind==='withdrawal' ? 'Check it, then save it to your challenge. Nothing changes until you do.' : 'Check it, then save it to your challenge. Only new money you set aside counts, and nothing is saved until you do.'}</p><button type="button" className="secondary-button" onClick={event=>{event.currentTarget.focus();onReview()}}>{intake.kind==='purchase'?'Review purchase':'Review savings'}</button></section>
}
