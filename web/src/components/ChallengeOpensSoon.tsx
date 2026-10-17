import { useBrand } from '../contexts/brandContextValue'
import './SavingsChallengeHome.css'

// Shown on Home while a sealed savings challenge is not open yet, or is paused.
export function ChallengeOpensSoon() {
  const { assistantName } = useBrand()
  return <section className="savings-home screen-grid" aria-label="Savings challenge">
    <div className="screen-heading">
      <p className="eyebrow">Home</p>
      <h2 data-page-heading tabIndex={-1}>Your savings challenge opens soon</h2>
      <p>You are all set for now. Your program team will open the challenge, and your plan, daily check-in and savings will show up right here.</p>
    </div>
    <div className="panel" role="status">
      <h3>Nothing to do yet</h3>
      <p>Until it opens, nothing is counted toward your challenge and {assistantName} cannot record savings or purchases for it. Come back soon.</p>
    </div>
  </section>
}
