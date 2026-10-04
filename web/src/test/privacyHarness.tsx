import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { ChallengePrivacyDialog } from '../components/ChallengePrivacyDialog'
import { privacyFixture, privacyScope, syntheticPrivacyApi } from './privacyFixtures'
import { ApiRequestError } from '../api'
import '../index.css'
import '../App.css'
const api = syntheticPrivacyApi()
const scenario = new URLSearchParams(window.location.search).get('scenario')
if (scenario === 'uncertain') {
  let attempts = 0
  api.mutate = async () => { if (++attempts === 1) throw new Error('Synthetic lost response'); return {} }
  api.status = async () => ({ state: 'unknown', can_retry: true, actor_scope: privacyScope })
}
if (scenario === 'held') {
  api.candidates = async () => { throw new ApiRequestError('Synthetic program held. New sharing unavailable.', { status: 403 }) }
  api.privacy = async () => ({ ...privacyFixture, grants: [{ id: 20, kind: 'coach_summary', recipient_user_id: 903, granted: true, selected_records: [], expires_at: null, policy_version: 'challenge_privacy_v1', lock_version: 3 }] })
}
export function Harness() {
  const [open, setOpen] = useState(false)
  return <main style={{ padding: 24 }}><h1>Synthetic privacy QA</h1><p>Fictional fixtures only. No real records, sharing or messages.</p><button onClick={() => setOpen(true)}>Open private controls</button>{open && <ChallengePrivacyDialog actorScope={privacyScope} participant documentImportId={500} onClose={() => setOpen(false)} api={api} />}</main>
}
createRoot(document.getElementById('root')!).render(<Harness />)
