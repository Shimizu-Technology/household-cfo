import { useEffect, useState } from 'react'
import { fetchAdminPlaidHealth } from '../../api'
import type { AdminPlaidHealth } from '../../api'

// Which bank connections are working. Status only, never balances or transactions.
export function BankHealth() {
  const [health, setHealth] = useState<AdminPlaidHealth | null>(null)
  const [error, setError] = useState(false)
  useEffect(() => { let live = true; fetchAdminPlaidHealth().then(next => { if (live) setHealth(next) }).catch(() => { if (live) setError(true) }); return () => { live = false } }, [])
  // A failed read says so and nothing else: "0 connected" would claim something nobody checked.
  if (error) return <p className="admin-alert error" role="alert">Bank connection status isn’t available right now. Open this again in a moment.</p>
  if (!health) return <p role="status" className="admin-muted">Checking bank connections…</p>
  return <div className="admin-bank">
    <p className="admin-muted">Only the status of each connection is shown, never balances or transactions.</p>
    <p className="admin-bank-summary"><span><strong>{health.summary.connected}</strong> connected</span> · <span><strong>{health.summary.healthy}</strong> working</span> · <span className={health.summary.attention_required > 0 ? 'is-attention' : ''}><strong>{health.summary.attention_required}</strong> need attention</span></p>
    {health.items.length === 0 ? <p className="admin-muted">No bank connections yet.</p> : <ul className="admin-list">{health.items.map(item => <li key={item.id} className="admin-bank-row">
      <strong>{item.institution_name}</strong>
      <span>{item.household.name} · {item.account_count} {item.account_count === 1 ? 'account' : 'accounts'}</span>
      <span className="admin-list-meta"><span className={`admin-pill ${item.health.state === 'healthy' ? 'is-joined' : ['stale', 'action_required', 'error'].includes(item.health.state) ? 'is-bounced' : 'is-invited'}`}>{item.health.label}</span> {item.health.message}</span>
      <span>{item.health.last_successful_update_at ? `Last update ${new Date(item.health.last_successful_update_at).toLocaleDateString()}` : 'No update yet'}</span>
    </li>)}</ul>}
  </div>
}
