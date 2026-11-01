import type { ChallengeTimeline as Timeline } from '../lib/savingsChallenge'
import { savingsDollars } from '../lib/savingsChallenge'
import { formatDay } from '../lib/plainDates'
import './ChallengeTimeline.css'
export function ChallengeTimeline({ timeline, onDay, onCheckpoint }: { timeline: Timeline; onDay?: (date: string) => void; onCheckpoint?: () => void }) {
  const due = timeline.checkpoints_due[0]
  return <section className="challenge-timeline" aria-label="Your 90 days">
    {due && <button type="button" className="savings-link" onClick={onCheckpoint}>Day {due} ready to review</button>}
    <div className="challenge-days" role="list" aria-label="Day-by-day challenge record">
      {timeline.days.map(day => {
        const state = day.future ? 'Ahead' : day.check_in === 'no_spend' ? 'No spending' : day.check_in === 'spending' ? 'Checked in' : day.purchase_count ? 'Purchases saved; check-in unfinished' : 'Not checked in'
        const deposit = day.deposit_cents === null ? '' : `; ${savingsDollars(day.deposit_cents)} set aside, after withdrawals`
        return <div role="listitem" key={day.day}><button type="button" disabled={day.future || !onDay} data-state={day.future ? 'future' : day.check_in} data-deposit={Boolean(day.deposit_cents && day.deposit_cents > 0)} aria-label={`Day ${day.day}, ${formatDay(day.local_on)}: ${state}${deposit}`} title={`${state}${deposit}`} onClick={() => onDay?.(day.local_on)}><span>{day.day}</span><span aria-hidden="true">{day.check_in === 'no_spend' ? '○' : day.check_in === 'spending' ? '✓' : '·'}{day.deposit_cents && day.deposit_cents > 0 ? ' +' : ''}</span></button></div>
      })}
    </div>
    <ul className="challenge-days-legend" role="list" aria-label="Day symbols">
      <li>✓ Checked in</li><li>○ No spending</li><li>+ Set aside</li><li>· Not checked in</li>
    </ul>
    <p className="savings-caption challenge-days-swipe">Swipe for all 90 days</p>
  </section>
}
