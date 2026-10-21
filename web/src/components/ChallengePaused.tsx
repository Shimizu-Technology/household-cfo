import type { ReactNode } from 'react'
import { useBrand } from '../contexts/brandContextValue'
import './SavingsChallengeHome.css'

// Shown on Home while a savings challenge the participant is part of is paused.
// Read-only: nothing here records money. Their own record stays downloadable.
export function ChallengePaused({ joined, children }: { joined: boolean; children?: ReactNode }) {
  const { assistantName } = useBrand()
  return <section className="savings-home screen-grid" aria-label="Savings challenge">
    <div className="screen-heading">
      <h2 data-page-heading tabIndex={-1}>Your savings challenge is paused</h2>
    </div>
    <div className="savings-state" role="status">
      <p>{joined
        ? 'Your program team paused it for now. Your record is safe and nothing has been lost. You can continue right where you left off when it resumes.'
        : 'Your program team paused it for now. You can join and continue when it resumes.'}</p>
      <p className="savings-caption">While it’s paused, new savings and purchases can’t be added, and {assistantName} can’t record them for the challenge.</p>
    </div>
    {children && <div className="savings-rows">{children}</div>}
  </section>
}
