import { useCallback, useState, type KeyboardEvent } from 'react'
import type { AdminPersonaAssignableCohort } from '../api'
import { CohortReleaseStudio } from './CohortReleaseStudio'
import { CohortRolloutStudio } from './CohortRolloutStudio'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

type View = 'release' | 'rollout'

export function ReleaseAndRolloutStudio({
  cohorts,
  cohortsLoading,
  mutationLifecycle,
  selectedCohortId,
  onSelectedCohortIdChange,
  onDirtyChange,
}: {
  cohorts: AdminPersonaAssignableCohort[]
  cohortsLoading: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  selectedCohortId: number | null
  onSelectedCohortIdChange: (cohortId: number | null) => void
  onDirtyChange: (dirty: boolean) => void
}) {
  const [view, setView] = useState<View>('release')
  const [rolloutDirty, setRolloutDirty] = useState(false)
  const [rolloutRefresh, setRolloutRefresh] = useState(0)
  const handleDirtyChange = useCallback((dirty: boolean) => {
    setRolloutDirty(dirty)
    onDirtyChange(dirty)
  }, [onDirtyChange])
  const allowReleaseAction = useCallback(() => (
    !rolloutDirty || window.confirm('Recording a new release will reset the rollout plan you have not recorded. Continue and discard that plan after the release is sealed?')
  ), [rolloutDirty])
  const handleReleaseChange = useCallback(() => {
    setRolloutDirty(false)
    onDirtyChange(false)
    setRolloutRefresh((value) => value + 1)
  }, [onDirtyChange])

  if (cohortsLoading && cohorts.length === 0) {
    return <article className="panel coach-empty coach-empty-main" role="status">Loading manageable cohorts…</article>
  }
  if (cohorts.length === 0) {
    return <article className="panel coach-empty coach-empty-main"><h3>No manageable cohorts yet.</h3><p>Assign this coach to a cohort before preparing a release or rollout.</p></article>
  }

  const chooseCohort = (cohortId: number) => {
    if (cohortId === selectedCohortId || mutationLifecycle.pending) return
    if (rolloutDirty && !window.confirm('Discard the rollout plan you have not recorded and switch cohorts?')) return
    onSelectedCohortIdChange(cohortId)
    setRolloutDirty(false)
    onDirtyChange(false)
  }

  function handleViewKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    const tabs = Array.from(event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>('[role="tab"]') ?? [])
    const currentIndex = tabs.indexOf(event.currentTarget)
    let nextIndex: number
    if (event.key === 'ArrowRight') nextIndex = (currentIndex + 1) % tabs.length
    else if (event.key === 'ArrowLeft') nextIndex = (currentIndex - 1 + tabs.length) % tabs.length
    else if (event.key === 'Home') nextIndex = 0
    else if (event.key === 'End') nextIndex = tabs.length - 1
    else return
    event.preventDefault()
    const nextView = nextIndex === 0 ? 'release' : 'rollout'
    setView(nextView)
    tabs[nextIndex]?.focus()
  }

  return (
    <section className="release-rollout-studio">
      <div className="cohort-release-truth" role="note">
        <span className="cohort-release-truth-icon" aria-hidden="true"><EvidenceIcon /></span>
        <div>
          <strong>Seal first. Then activate in controlled waves.</strong>
          <p>Sealing or restoring only prepares a release. In a runtime-enabled rollout, starting and advancing move that wave immediately, completion makes the release the cohort default, and rollback restores the captured baseline for still-current exposed enrollments. A rollout labeled pre-cutover remains record-only until it is closed.</p>
          <small>Every action is reviewed, recorded, and safe to retry.</small>
        </div>
      </div>

      <article className="panel release-rollout-heading">
        <div>
          <p className="eyebrow">Release &amp; rollout</p>
          <h3>Prepare one cohort from evidence to completion</h3>
          <p>Seal the assistant and tools together, then choose how participants move through the rollout.</p>
        </div>
        <label>
          <span>Cohort</span>
          <select value={selectedCohortId ?? ''} disabled={mutationLifecycle.pending} onChange={(event) => chooseCohort(Number(event.target.value))}>
            {cohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name} · {titleize(cohort.status)}</option>)}
          </select>
        </label>
      </article>

      <div className="release-rollout-tabs" role="tablist" aria-label="Release and rollout steps">
        <button type="button" role="tab" id="release-rollout-tab-release" aria-controls="release-rollout-panel-release" aria-selected={view === 'release'} tabIndex={view === 'release' ? 0 : -1} onKeyDown={handleViewKeyDown} onClick={() => setView('release')} disabled={mutationLifecycle.pending}>
          <span>1</span><strong>Release</strong><small>Verify and seal</small>
        </button>
        <button type="button" role="tab" id="release-rollout-tab-rollout" aria-controls="release-rollout-panel-rollout" aria-selected={view === 'rollout'} tabIndex={view === 'rollout' ? 0 : -1} onKeyDown={handleViewKeyDown} onClick={() => setView('rollout')} disabled={mutationLifecycle.pending}>
          <span>2</span><strong>Rollout</strong><small>Plan and manage waves</small>
        </button>
      </div>

        <div role="tabpanel" id="release-rollout-panel-release" aria-labelledby="release-rollout-tab-release" hidden={view !== 'release'}>
          <CohortReleaseStudio
            cohorts={cohorts}
            cohortsLoading={cohortsLoading}
            mutationLifecycle={mutationLifecycle}
            selectedCohortId={selectedCohortId}
            onSelectedCohortIdChange={onSelectedCohortIdChange}
            embedded
            beforeReleaseAction={allowReleaseAction}
            onReleaseChange={handleReleaseChange}
          />
        </div>
        <div role="tabpanel" id="release-rollout-panel-rollout" aria-labelledby="release-rollout-tab-rollout" hidden={view !== 'rollout'}>
          <CohortRolloutStudio
            key={`${selectedCohortId ?? 'none'}-${rolloutRefresh}`}
            cohortId={selectedCohortId}
            mutationLifecycle={mutationLifecycle}
            onDirtyChange={handleDirtyChange}
          />
        </div>
    </section>
  )
}

function titleize(value: string) {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function EvidenceIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 3.75h9l3 3V20.25H6zM15 3.75v3h3M9 11.25h6M9 15h4.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" /></svg>
}
