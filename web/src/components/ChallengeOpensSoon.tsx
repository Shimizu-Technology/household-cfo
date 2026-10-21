import { useBrand } from '../contexts/brandContextValue'
import './SavingsChallengeHome.css'

// Shown on Home while a sealed savings challenge is not open yet.
export function ChallengeOpensSoon() {
  const { assistantName } = useBrand()
  return <section className="savings-home screen-grid" aria-label="Savings challenge">
    <div className="screen-heading">
      <h2 data-page-heading tabIndex={-1}>Your savings challenge opens soon</h2>
    </div>
    <div className="savings-state" role="status">
      <p>Nothing to do yet. When your program team opens it, your target, daily check-in and savings will show up here.</p>
      <p className="savings-caption">Until then, nothing is counted and {assistantName} cannot record savings or purchases for the challenge.</p>
    </div>
  </section>
}
