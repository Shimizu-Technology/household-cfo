import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { OptionalDebtReview } from '../components/OptionalDebtReview'
import { ApiRequestError } from '../api'
import { debtFixtureScope, syntheticDebtApi } from './optionalDebtFixtures'
import '../index.css'
import '../App.css'
import '../dialogViewport.css'
import { useDialogViewport } from '../lib/useDialogViewport'
const scenario = new URLSearchParams(window.location.search).get('scenario'), api = syntheticDebtApi({ pending: scenario === 'cold-approve' })
if (scenario === 'uncertain') { const original = api.mutate; let calls = 0; api.mutate = async (...args) => { if (++calls === 1) throw new Error('Synthetic lost response. The server did not confirm this request.'); return original(...args) } }
if (scenario === 'held') api.summary = async () => { throw new ApiRequestError('Synthetic program held.', { status: 403 }) }
export function Harness() { useDialogViewport(); const [open, setOpen] = useState(false); return <main style={{ padding: 24 }}><h1>Synthetic optional card QA</h1><p>Fictional terms only. No real documents, payments or sharing.</p><button onClick={() => setOpen(true)}>Open optional card review</button>{open && <OptionalDebtReview actorScope={debtFixtureScope} cohortId={debtFixtureScope.cohort_id} onClose={() => setOpen(false)} api={api}/>}</main> }
createRoot(document.getElementById('root')!).render(<Harness/>)
