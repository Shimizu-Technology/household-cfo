// @vitest-environment jsdom
import { useState, type ReactNode } from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as api from '../api'
import * as enterprise from '../enterpriseApi'
import * as evidence from '../evidenceApi'
import * as setup from '../setupHelpApi'
import { baselineContext, baselineCurrent, baselineScope, baselinePreview } from '../test/baselineFixtures'
import { dailyContext } from '../test/dailyFixtures'
import { evidencePage } from '../test/evidenceFixtures'
import { privacyScope, syntheticPrivacyApi } from '../test/privacyFixtures'
import { debtFixtureScope, syntheticDebtApi } from '../test/optionalDebtFixtures'
import { enterpriseDetail, enterpriseMember, enterpriseOrganization, enterpriseUser } from '../qa/enterpriseFixtures'
import { BaselineReview } from './BaselineReview'
import { ChallengeToday } from './ChallengeToday'
import { ChallengePrivacyDialog } from './ChallengePrivacyDialog'
import { EarlierMiaConversations } from './EarlierMiaConversations'
import { OptionalDebtReview } from './OptionalDebtReview'
import { PilotFeedbackDialog } from './PilotFeedbackDialog'
import { SavingsEvidenceDialog } from './SavingsEvidenceDialog'
import { EnterpriseSettings } from './EnterpriseSettings'
import { SetupHelpDialog } from './SetupHelpDialog'
import { StatementLineSheet } from './StatementSheets'
import { ConfirmHost } from './ConfirmHost'
import { confirmAction } from '../lib/confirmAction'
import { bindBaselineActor, setBaselineExpectedUser } from '../lib/baselineRecovery'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), fetchFinancialBaseline: vi.fn(), fetchBaselineContext: vi.fn(), previewFinancialBaseline: vi.fn(), fetchDailyContext: vi.fn(), fetchDailyPage: vi.fn(), fetchEarlierMiaMessages: vi.fn(), fetchMyPilotFeedback: vi.fn() }))
vi.mock('../enterpriseApi')
vi.mock('../evidenceApi')
vi.mock('../setupHelpApi')

function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done }); return { promise, resolve } }
function Owner({ children }: { children: (close: () => void) => ReactNode }) {
  const [open, setOpen] = useState(true)
  return <>{open && children(() => setOpen(false))}<textarea aria-label="Composer" /></>
}
function dismiss() { fireEvent.keyDown(document, { key: 'Escape' }) }
beforeEach(() => {
  vi.resetAllMocks(); sessionStorage.clear(); setBaselineExpectedUser(901); bindBaselineActor(baselineScope)
  // Baseline code must really enter its delayed path, rather than the jsdom fallback.
  vi.stubGlobal('CSS', { supports: () => true })
  Object.defineProperty(HTMLElement.prototype, 'getAnimations', { configurable: true, value: () => [{ finished: new Promise(() => {}) } as Animation] })
  HTMLDialogElement.prototype.showModal = function () { this.open = true }
  HTMLDialogElement.prototype.close = function () { this.open = false }
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals() })

it('EnterpriseSettings ignores a portal response immediately after dismissal', async () => {
  const pending = deferred<Awaited<ReturnType<typeof enterprise.openEnterprisePortal>>>()
  const navigate = vi.fn()
  const realWindow = window
  vi.stubGlobal('window', new Proxy(realWindow, { get(target, key) { return key === 'location' ? { origin: realWindow.location.origin, assign: navigate } : Reflect.get(target, key) } }))
  vi.mocked(enterprise.fetchEnterpriseOrganizations).mockResolvedValue({ enterprise_organizations: [enterpriseOrganization()] })
  vi.mocked(enterprise.fetchEnterpriseOrganization).mockResolvedValue(enterpriseDetail())
  vi.mocked(enterprise.fetchEnterpriseMembers).mockResolvedValue({ memberships: [enterpriseMember()] })
  vi.mocked(enterprise.openEnterprisePortal).mockReturnValue(pending.promise)
  render(<Owner>{close => <EnterpriseSettings currentUser={enterpriseUser()} onClose={close} />}</Owner>)
  fireEvent.click(await screen.findByRole('button', { name: 'Configure company sign-in' }))
  dismiss()
  await act(async () => pending.resolve({ url: 'https://setup.workos.com/setup', expires_at: new Date(Date.now() + 60000).toISOString() }))
  expect(navigate).not.toHaveBeenCalled()
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('StatementLineSheet checks canClose at Escape, retaining the draft when a save later fails', async () => {
  function SheetOwner() {
    const [open, setOpen] = useState(true), [busy, setBusy] = useState(true)
    return <><button onClick={() => setBusy(false)}>Fail save</button>{open && <StatementLineSheet line={{ eventId: 1, kind: 'spending', merchant: 'Payless', postedOn: '2026-10-01', amountCents: 1200, categoryId: null, leftOut: false }} categories={[]} busy={busy} error={busy ? null : 'Save failed. Try again.'} onSave={vi.fn()} onLeaveOut={vi.fn()} onClose={() => setOpen(false)} />}</>
  }
  render(<SheetOwner />)
  fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Keep my correction' } })
  dismiss()
  fireEvent.click(screen.getByRole('button', { name: 'Fail save' }))
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 230)) })
  expect(screen.getByLabelText('Name')).toHaveProperty('value', 'Keep my correction')
  expect(screen.getByRole('alert').textContent).toBe('Save failed. Try again.')
})

it('BaselineReview aborts private snapshot reads on dismissal before a late response', async () => {
  const pending = deferred<Awaited<ReturnType<typeof api.fetchFinancialBaseline>>>()
  vi.mocked(api.fetchFinancialBaseline).mockReturnValue(pending.promise)
  vi.mocked(api.fetchBaselineContext).mockResolvedValue(baselineContext)
  render(<Owner>{close => <BaselineReview scope={baselineScope} onClose={close} onReviewStatements={vi.fn()} />}</Owner>)
  await waitFor(() => expect(api.fetchFinancialBaseline).toHaveBeenCalledOnce())
  const signal = vi.mocked(api.fetchFinancialBaseline).mock.calls[0].find(arg => arg instanceof AbortSignal) as AbortSignal
  dismiss()
  expect(signal.aborted).toBe(true)
  await act(async () => pending.resolve(baselineCurrent()))
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('ChallengeToday aborts its private context read before a late response can update Today', async () => {
  const pending = deferred<Awaited<ReturnType<typeof api.fetchDailyContext>>>()
  vi.mocked(api.fetchDailyContext).mockReturnValue(pending.promise)
  render(<Owner>{close => <ChallengeToday scope={baselineScope} onClose={close} onStatements={vi.fn()} onBaseline={vi.fn()} />}</Owner>)
  await waitFor(() => expect(api.fetchDailyContext).toHaveBeenCalledOnce())
  const signal = vi.mocked(api.fetchDailyContext).mock.calls[0].find(arg => arg instanceof AbortSignal) as AbortSignal
  dismiss(); expect(signal.aborted).toBe(true)
  await act(async () => pending.resolve(dailyContext))
  expect(api.fetchDailyPage).not.toHaveBeenCalled()
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('ChallengePrivacyDialog immediately aborts native-dialog private reads', async () => {
  const privacy = syntheticPrivacyApi(), page = await privacy.controls(null), pending = deferred<Awaited<ReturnType<typeof privacy.controls>>>()
  vi.spyOn(privacy, 'privacy')
  privacy.controls = vi.fn().mockReturnValue(pending.promise)
  render(<Owner>{close => <ChallengePrivacyDialog actorScope={privacyScope} participant api={privacy} onClose={close} />}</Owner>)
  await waitFor(() => expect(privacy.controls).toHaveBeenCalledOnce())
  const signal = vi.mocked(privacy.controls).mock.calls[0][1]!
  fireEvent(screen.getByRole('dialog'), new Event('cancel', { bubbles: false, cancelable: true }))
  expect(signal.aborted).toBe(true)
  await act(async () => pending.resolve(page))
  expect(privacy.privacy).not.toHaveBeenCalled()
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('EarlierMiaConversations aborts history at dismissal and ignores late messages', async () => {
  const pending = deferred<Awaited<ReturnType<typeof api.fetchEarlierMiaMessages>>>()
  vi.mocked(api.fetchEarlierMiaMessages).mockReturnValue(pending.promise)
  render(<Owner>{close => <EarlierMiaConversations onClose={close} />}</Owner>)
  await waitFor(() => expect(api.fetchEarlierMiaMessages).toHaveBeenCalledOnce())
  const signal = vi.mocked(api.fetchEarlierMiaMessages).mock.calls[0][1]!
  dismiss(); expect(signal.aborted).toBe(true)
  await act(async () => pending.resolve({ picture: 'history', read_only: true, messages: [], oldest_message_id: null, has_older_messages: false, older_message_count: 0 }))
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('OptionalDebtReview does not start five private reads when a summary lands after dismissal', async () => {
  const debt = syntheticDebtApi(), summary = await debt.summary(701), pending = deferred<typeof summary>()
  debt.summary = vi.fn().mockReturnValue(pending.promise)
  vi.spyOn(debt, 'records')
  debt.candidates = vi.fn(debt.candidates)
  debt.householdCandidates = vi.fn(debt.householdCandidates)
  render(<Owner>{close => <OptionalDebtReview actorScope={debtFixtureScope} cohortId={701} onClose={close} api={debt} />}</Owner>)
  await waitFor(() => expect(debt.summary).toHaveBeenCalledOnce())
  dismiss()
  await act(async () => pending.resolve(summary))
  expect(debt.records).not.toHaveBeenCalled()
  expect(debt.candidates).not.toHaveBeenCalled()
  expect(debt.householdCandidates).not.toHaveBeenCalled()
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('PilotFeedbackDialog aborts report history before a late response can render', async () => {
  const pending = deferred<Awaited<ReturnType<typeof api.fetchMyPilotFeedback>>>()
  vi.mocked(api.fetchMyPilotFeedback).mockReturnValue(pending.promise)
  render(<Owner>{close => <PilotFeedbackDialog initialWorkflow="home" onClose={close} onSubmit={vi.fn()} />}</Owner>)
  fireEvent.click(screen.getByText('My submitted reports'))
  await waitFor(() => expect(api.fetchMyPilotFeedback).toHaveBeenCalledOnce())
  const signal = vi.mocked(api.fetchMyPilotFeedback).mock.calls[0].find(arg => arg instanceof AbortSignal) as AbortSignal
  dismiss(); expect(signal.aborted).toBe(true)
  await act(async () => pending.resolve({ feedback_reports: [], next_cursor: null }))
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('SavingsEvidenceDialog never starts the candidate read after dismissal', async () => {
  const pending = deferred<Awaited<ReturnType<typeof evidence.fetchSavingsEvidence>>>()
  vi.mocked(evidence.fetchSavingsEvidence).mockReturnValue(pending.promise)
  render(<Owner>{close => <SavingsEvidenceDialog actorScope={baselineScope} entryVersionId={11} onClose={close} onChanged={vi.fn()} />}</Owner>)
  await waitFor(() => expect(evidence.fetchSavingsEvidence).toHaveBeenCalledOnce())
  const signal = vi.mocked(evidence.fetchSavingsEvidence).mock.calls[0][2]!
  dismiss(); expect(signal.aborted).toBe(true)
  await act(async () => pending.resolve(evidencePage()))
  expect(evidence.fetchSavingsEvidenceCandidates).not.toHaveBeenCalled()
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('SetupHelpDialog releases the focus trap before next-frame composer focus', async () => {
  vi.mocked(setup.fetchSetupHelp).mockReturnValue(new Promise(() => {}))
  render(<Owner>{close => <SetupHelpDialog scopeKey="actor901:hh1" userId={901} householdId={1} onClose={close} onTopic={() => true} onRestart={vi.fn()} onAskMia={() => { requestAnimationFrame(() => screen.getByLabelText('Composer').focus()); return true }} />}</Owner>)
  const ask = screen.getByRole('button', { name: 'Talk through a correction with Mia' })
  fireEvent.click(ask)
  await waitFor(() => expect(document.activeElement).toBe(screen.getByLabelText('Composer')))
})

it('ConfirmHost answers the first dismissal once even when a second confirmation arrives during its visual exit', async () => {
  render(<ConfirmHost />)
  const answered = vi.fn()
  act(() => { void confirmAction('First question').then(answered) })
  dismiss()
  act(() => { void confirmAction('Second question') })
  await act(async () => { await Promise.resolve() })
  expect(answered).toHaveBeenCalledExactlyOnceWith(false)
  expect(screen.queryByText('First question')).toBeNull()
  expect(screen.getByText('Second question')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Continue' }))
  expect(answered).toHaveBeenCalledOnce()
})

it('BaselineReview cannot render a late preview or move composer focus after dismissal', async () => {
  vi.mocked(api.fetchFinancialBaseline).mockResolvedValue(baselineCurrent())
  vi.mocked(api.fetchBaselineContext).mockResolvedValue(baselineContext)
  const pending = deferred<Awaited<ReturnType<typeof api.previewFinancialBaseline>>>()
  vi.mocked(api.previewFinancialBaseline).mockReturnValue(pending.promise)
  render(<Owner>{close => <BaselineReview scope={baselineScope} onClose={close} onReviewStatements={vi.fn()} />}</Owner>)
  await screen.findByText('No spending snapshot yet')
  fireEvent.change(screen.getByLabelText('Period begins'), { target: { value: '2026-09-01' } })
  fireEvent.change(screen.getByLabelText('Period ends'), { target: { value: '2026-09-30' } })
  fireEvent.click(screen.getByRole('button', { name: 'Preview my snapshot' }))
  await waitFor(() => expect(api.previewFinancialBaseline).toHaveBeenCalledOnce())
  const [request, signal] = vi.mocked(api.previewFinancialBaseline).mock.calls[0]
  dismiss()
  expect(signal!.aborted).toBe(true)
  screen.getByLabelText('Composer').focus()
  await act(async () => pending.resolve(baselinePreview(request)))
  expect(screen.queryByRole('region', { name: 'Snapshot preview' })).toBeNull()
  expect(document.activeElement).toBe(screen.getByLabelText('Composer'))
})
