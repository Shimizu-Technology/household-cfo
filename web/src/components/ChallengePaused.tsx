import type { ReactNode } from 'react'
import { useBrand } from '../contexts/brandContextValue'
import './SavingsChallengeHome.css'

// Shown on Home while a savings challenge the participant is part of is paused.
// Read-only: nothing here records money. Their own record stays downloadable.
export function ChallengePaused({ joined, children }: { joined: boolean; children?: ReactNode }) {
  const { assistantName } = useBrand()
  return <section className="savings-home screen-grid" aria-label="Savings challenge">
    <div className="screen-heading">
      <p className="eyebrow">Home</p>
      <h2 data-page-heading tabIndex={-1}>Your savings challenge is paused</h2>
      <p>{joined
        ? 'Your program team has paused the challenge for now. Your record is safe and nothing has been lost. You will be able to continue right where you left off when it resumes.'
        : 'Your program team has paused the challenge for now. You will be able to join and continue when it resumes.'}</p>
    </div>
    <div className="panel" role="status">
      <h3>Nothing to do right now</h3>
      <p>While it is paused, new savings and purchases cannot be added, and {assistantName} cannot record them for the challenge. {joined ? 'Your approved records are kept exactly as they were.' : 'Nothing is counted yet.'}</p>
    </div>
    {children}
  </section>
}
