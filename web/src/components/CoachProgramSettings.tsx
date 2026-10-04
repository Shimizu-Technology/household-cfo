import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import {
  createCoachWorkspace, fetchCoachWorkspaceSettings, fetchWorkspaceBrand,
  previewWorkspaceBrand, publishWorkspaceBrand, restoreWorkspaceBrandVersion,
  saveWorkspaceBrand, updateCoachWorkspaceSettings,
  type BrandConfig, type CoachWorkspaceSettings, type CoachWorkspaceSettingsInput,
  type CurrentUser, type WorkspaceBrandConfiguration, type WorkspaceBrandPreview,
} from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import './CoachProgramSettings.css'

const blankIdentity: CoachWorkspaceSettingsInput = { name: '', coach_profile: { display_name: '', title: 'Financial coach', bio: '' } }
const releaseImpact = 'Publishing updates the program’s front door. Participants on a sealed release keep its brand until you launch or roll out a release that includes this version.'

function identityValues(workspace: CoachWorkspaceSettings): CoachWorkspaceSettingsInput {
  return { name: workspace.name, coach_profile: workspace.coach_profile ?? blankIdentity.coach_profile }
}
function message(error: unknown) { return error instanceof Error ? error.message : 'Program settings could not be saved. Try again.' }

export function CreateCoachProgram({ disabled = false, onDirtyChange, onPendingChange, onCreated }: {
  disabled?: boolean
  onDirtyChange?: (dirty: boolean) => void
  onPendingChange?: (pending: boolean) => void
  onCreated?: (workspace: CoachWorkspaceSettings) => void
}) {
  const { refreshCurrentUser } = useAuthContext()
  const [open, setOpen] = useState(false)
  const [values, setValues] = useState<CoachWorkspaceSettingsInput>(blankIdentity)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const mounted = useRef(true)
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  const creationKeys = useRef(new Map<string, string>())
  const dirty = open && JSON.stringify(values) !== JSON.stringify(blankIdentity)
  useEffect(() => { onDirtyChange?.(dirty || busy) }, [busy, dirty, onDirtyChange])
  useEffect(() => () => onDirtyChange?.(false), [onDirtyChange])
  useEffect(() => { onPendingChange?.(busy) }, [busy, onPendingChange])
  useEffect(() => () => onPendingChange?.(false), [onPendingChange])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (busy || disabled) return
    setBusy(true); setError(null); setNotice(null)
    try {
      const fingerprint = JSON.stringify(values)
      let requestKey = creationKeys.current.get(fingerprint)
      if (!requestKey) { requestKey = crypto.randomUUID(); creationKeys.current.set(fingerprint, requestKey) }
      const created = await createCoachWorkspace(values, requestKey)
      if (!mounted.current) return
      creationKeys.current.clear()
      setValues(blankIdentity); setOpen(false)
      setNotice(`${created.name} was created. Choose it in the workspace selector to finish its assistant and branding.`)
      await refreshCurrentUser()
      onCreated?.(created)
    } catch (caught) { if (mounted.current) setError(message(caught)) }
    finally { if (mounted.current) setBusy(false) }
  }

  return <article className="panel program-create">
    <header><div><p className="eyebrow">Coach programs</p><h3>Create a program</h3><p>Give each coach a separate workspace for their assistant, branding, and groups.</p></div>
      {!open && <Button variant="secondary" disabled={disabled || busy} onClick={() => setOpen(true)}>Create program</Button>}
    </header>
    {error && <p role="alert" className="coach-studio-alert is-error">{error}</p>}
    {notice && <p role="status" className="coach-studio-alert is-success">{notice}</p>}
    {open && <form onSubmit={(event) => void submit(event)}>
      <fieldset disabled={busy || disabled}><IdentityFields values={values} onChange={setValues} />
        <div className="program-actions"><Button type="submit">{busy ? 'Creating…' : 'Create program'}</Button><Button variant="ghost" onClick={() => { setOpen(false); setValues(blankIdentity) }}>Cancel</Button></div>
      </fieldset>
      <p className="program-help">You will own this workspace. Creating it does not invite anyone or launch a participant program.</p>
    </form>}
  </article>
}

export function CoachProgramSettings({ workspaceId, currentUser, mutationLifecycle, onDirtyChange }: {
  workspaceId: number | null
  currentUser: CurrentUser
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange: (dirty: boolean) => void
}) {
  const { refreshCurrentUser } = useAuthContext()
  const [workspace, setWorkspace] = useState<CoachWorkspaceSettings | null>(null)
  const [identity, setIdentity] = useState<CoachWorkspaceSettingsInput>(blankIdentity)
  const [brand, setBrand] = useState<WorkspaceBrandConfiguration | null>(null)
  const [draft, setDraft] = useState<BrandConfig | null>(null)
  const [preview, setPreview] = useState<WorkspaceBrandPreview | null>(null)
  const [loading, setLoading] = useState(workspaceId !== null)
  const [pending, setPending] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [createDirty, setCreateDirty] = useState(false)
  const alive = useRef(true)
  const loadSequence = useRef(0)
  const operationKeys = useRef(new Map<string, string>())
  const identityDirty = Boolean(workspace && JSON.stringify(identity) !== JSON.stringify(identityValues(workspace)))
  const brandDirty = Boolean(brand && draft && JSON.stringify(draft) !== JSON.stringify(brand.draft))
  const dirty = identityDirty || brandDirty || createDirty
  const busy = pending !== null || mutationLifecycle.pending

  useEffect(() => { alive.current = true; return () => { alive.current = false; loadSequence.current += 1 } }, [])
  useEffect(() => { onDirtyChange(dirty) }, [dirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  const load = useCallback(async () => {
    if (workspaceId === null) return
    const sequence = ++loadSequence.current
    setLoading(true); setError(null)
    try {
      const [nextWorkspace, nextBrand] = await Promise.all([fetchCoachWorkspaceSettings(workspaceId), fetchWorkspaceBrand()])
      if (!alive.current || sequence !== loadSequence.current) return
      setWorkspace(nextWorkspace); setIdentity(identityValues(nextWorkspace))
      setBrand(nextBrand); setDraft(nextBrand.draft); setPreview(null)
    } catch (caught) { if (alive.current && sequence === loadSequence.current) setError(message(caught)) }
    finally { if (alive.current && sequence === loadSequence.current) setLoading(false) }
  }, [workspaceId])
  useEffect(() => { let cancelled = false; queueMicrotask(() => { if (!cancelled) void load() }); return () => { cancelled = true } }, [load])

  function keyFor(action: string) {
    const operation = `${action}:${brand?.draft_revision}:${brand?.published_version?.id}`
    let key = operationKeys.current.get(operation)
    if (!key) { key = crypto.randomUUID(); operationKeys.current.set(operation, key) }
    return key
  }
  function acceptBrand(next: WorkspaceBrandConfiguration) {
    setBrand(next); setDraft(next.draft)
  }
  async function mutate(action: string, operation: (isCurrent: () => boolean) => Promise<void>) {
    if (busy) return
    const ticket = mutationLifecycle.begin()
    setPending(action); setError(null); setNotice(null)
    try { await operation(() => alive.current && mutationLifecycle.isCurrent(ticket)) }
    catch (caught) { if (alive.current && mutationLifecycle.isCurrent(ticket)) setError(message(caught)) }
    finally { mutationLifecycle.finish(ticket); if (alive.current) setPending(null) }
  }
  function saveIdentity(event: FormEvent) {
    event.preventDefault()
    if (!workspace?.permissions.manage || !identityDirty || brandDirty) return
    void mutate('identity', async (isCurrent) => {
      const next = await updateCoachWorkspaceSettings(workspace.id, { ...identity, revision: workspace.revision })
      if (!isCurrent()) return
      setWorkspace(next); setIdentity(identityValues(next)); setNotice('Program identity saved. Assistant voice and published branding are managed separately below.')
      await refreshCurrentUser()
    })
  }
  function updateBrand(next: BrandConfig) { setDraft(next); setPreview(null); setNotice(null) }
  function saveBrand(event: FormEvent) {
    event.preventDefault()
    if (!brand || !draft || !brand.permissions.edit || !brandDirty) return
    void mutate('brand', async (isCurrent) => {
      const next = await saveWorkspaceBrand(draft, brand.draft_revision)
      if (!isCurrent()) return
      acceptBrand(next); setPreview(null); setNotice('Brand draft saved. Preview it before publishing.')
    })
  }
  function runPreview() {
    if (!brand?.permissions.preview || brandDirty) return
    void mutate('preview', async (isCurrent) => {
      const result = await previewWorkspaceBrand(brand.draft_revision)
      if (!isCurrent()) return
      acceptBrand(result.brand_configuration); setPreview(result.preview); setNotice('This preview uses the exact saved brand draft.')
    })
  }
  function publish() {
    if (!brand?.permissions.publish || !preview || brandDirty) return
    if (!window.confirm(`${releaseImpact} Publish this exact preview?`)) return
    void mutate('publish', async (isCurrent) => {
      const result = await publishWorkspaceBrand({ draft_revision: brand.draft_revision, preview_digest: preview.digest, expected_published_version_id: brand.published_version?.id ?? null }, keyFor('publish'))
      if (!isCurrent()) return
      acceptBrand(result.brand_configuration); setPreview(null); setNotice(`Brand version ${result.published_version.number} published. ${releaseImpact}`)
    })
  }
  function restore(id: number, number: number) {
    if (!brand?.permissions.rollback || brandDirty) return
    if (!window.confirm(`Restore brand version ${number} as a new published version? ${releaseImpact}`)) return
    void mutate('restore', async (isCurrent) => {
      const result = await restoreWorkspaceBrandVersion(id, { draft_revision: brand.draft_revision, expected_published_version_id: brand.published_version?.id ?? null }, keyFor(`restore-${id}`))
      if (!isCurrent()) return
      acceptBrand(result.brand_configuration); setPreview(null); setNotice(`Brand version ${number} restored as version ${result.published_version.number}. ${releaseImpact}`)
    })
  }

  return <section className="program-settings" aria-busy={loading || busy}>
    <header><p className="eyebrow">Program settings</p><h3>Your program, in your voice and colors.</h3><p>Start with its name and coach identity, then review the participant welcome screen.</p></header>
    {currentUser.is_admin && <CreateCoachProgram disabled={busy || loading || identityDirty || brandDirty} onDirtyChange={setCreateDirty} />}
    {workspaceId === null ? <p className="coach-read-only">Choose a workspace above to edit its settings. You can create the first program here.</p> : <>
      {error && <div className="coach-studio-alert is-error" role="alert"><span>{error}</span><Button variant="ghost" disabled={busy} onClick={() => { if (!dirty || window.confirm('Discard unsaved program settings and reload?')) void load() }}>Reload settings</Button></div>}
      {notice && <p className="coach-studio-alert is-success" role="status">{notice}</p>}
      {loading ? <p role="status">Loading program settings…</p> : workspace && brand && draft && <>
        <form className="panel" onSubmit={saveIdentity}>
          <header><h3>Program and coach</h3><p>The workspace name helps staff choose the right program. The coach profile describes who is behind it.</p></header>
          <fieldset disabled={busy || !workspace.permissions.manage}><IdentityFields values={identity} onChange={setIdentity} /><Button type="submit" disabled={!identityDirty || brandDirty}>{pending === 'identity' ? 'Saving…' : 'Save program identity'}</Button></fieldset>
          {!workspace.permissions.manage && <p className="program-help">Only the workspace owner or a platform administrator can change program identity.</p>}
          {identityDirty && brandDirty && <p className="program-help">Save the brand draft below before saving program identity.</p>}
        </form>
        <form className="panel" onSubmit={saveBrand}>
          <header><h3>Participant branding</h3><p>{releaseImpact} Change the assistant’s name in Assistant voice.</p></header>
          <fieldset disabled={busy || !brand.permissions.edit}><BrandFields draft={draft} onChange={updateBrand} /></fieldset>
          {!brand.permissions.edit && <p className="program-help">Your workspace role can view this branding but cannot edit it.</p>}
          <div className="program-actions">
            <Button type="submit" disabled={busy || !brandDirty || !brand.permissions.edit}>{pending === 'brand' ? 'Saving…' : 'Save brand draft'}</Button>
            <Button variant="secondary" disabled={busy || brandDirty || !brand.permissions.preview} onClick={runPreview}>{pending === 'preview' ? 'Previewing…' : 'Preview welcome screen'}</Button>
            <Button disabled={busy || brandDirty || !brand.permissions.publish || !preview || preview.digest !== brand.preview?.digest} onClick={publish}>{pending === 'publish' ? 'Publishing…' : 'Publish branding'}</Button>
          </div>
          <p className="program-help">{brandDirty ? 'Save your changes before previewing.' : preview ? 'Exact saved draft previewed. Review the screen below before publishing.' : 'Preview the saved draft to enable publishing.'}</p>
        </form>
        {preview && <BrandWelcomePreview config={preview.brand} />}
        <details className="panel program-history"><summary>Brand version history ({brand.versions.length})</summary><div>
          {brand.versions.map((version) => <article key={version.id}><div><strong>Version {version.number}</strong><small>{new Date(version.published_at).toLocaleString()} · {version.published_by.full_name}</small>{version.restored_from_version && <small>Restored from version {version.restored_from_version.number}</small>}</div>
            {version.id === brand.published_version?.id ? <span className="coach-status is-current">Published</span> : <Button variant="ghost" size="compact" disabled={busy || brandDirty || !brand.permissions.rollback} onClick={() => restore(version.id, version.number)}>Restore as new version</Button>}
          </article>)}
        </div></details>
      </>}
    </>}
  </section>
}

function IdentityFields({ values, onChange }: { values: CoachWorkspaceSettingsInput; onChange: (next: CoachWorkspaceSettingsInput) => void }) {
  function profile(key: keyof CoachWorkspaceSettingsInput['coach_profile'], value: string) { onChange({ ...values, coach_profile: { ...values.coach_profile, [key]: value } }) }
  return <div className="program-fields">
    <label>Workspace name<input required maxLength={160} value={values.name} onChange={(event) => onChange({ ...values, name: event.target.value })} placeholder="Mrs. Mel’s program" /></label>
    <label>Coach display name<input required maxLength={120} value={values.coach_profile.display_name} onChange={(event) => profile('display_name', event.target.value)} placeholder="Mrs. Mel" /></label>
    <label>Coach title<input required maxLength={160} value={values.coach_profile.title} onChange={(event) => profile('title', event.target.value)} /></label>
    <label className="program-wide">About the coach<textarea maxLength={2000} rows={3} value={values.coach_profile.bio} onChange={(event) => profile('bio', event.target.value)} /></label>
  </div>
}

const themes: Record<string, Pick<BrandConfig, 'colors'>> = {
  rose: { colors: { primary: '#7b4a58', primary_hover: '#633944', primary_soft: '#f1e2e3', on_primary: '#ffffff', accent: '#b97352', focus: '#7b4a58' } },
  forest: { colors: { primary: '#375b48', primary_hover: '#294536', primary_soft: '#e5eee7', on_primary: '#ffffff', accent: '#9a7457', focus: '#375b48' } },
  ocean: { colors: { primary: '#315d7c', primary_hover: '#24445c', primary_soft: '#e2edf5', on_primary: '#ffffff', accent: '#a96e3c', focus: '#315d7c' } },
}
function BrandFields({ draft, onChange }: { draft: BrandConfig; onChange: (next: BrandConfig) => void }) {
  function field(key: keyof BrandConfig, value: string) { onChange({ ...draft, [key]: value }) }
  const theme = Object.entries(themes).find(([, value]) => value.colors.primary === draft.colors.primary)?.[0] ?? 'custom'
  return <div className="program-fields">
    <label>App name<input required maxLength={80} value={draft.product_name} onChange={(event) => field('product_name', event.target.value)} /></label>
    <label>Short name<input required maxLength={32} value={draft.short_name} onChange={(event) => field('short_name', event.target.value)} /></label>
    <label>Organization<input required maxLength={100} value={draft.organization_name} onChange={(event) => field('organization_name', event.target.value)} /></label>
    <label>Participant term<input required maxLength={48} value={draft.participant_role_term} onChange={(event) => field('participant_role_term', event.target.value)} /></label>
    <label className="program-wide">Tagline<input maxLength={180} value={draft.tagline ?? ''} onChange={(event) => field('tagline', event.target.value)} /></label>
    <label className="program-wide">Welcome heading<input maxLength={120} value={draft.welcome_heading ?? ''} onChange={(event) => field('welcome_heading', event.target.value)} /></label>
    <label className="program-wide">Welcome message<textarea rows={3} maxLength={320} value={draft.welcome_description ?? ''} onChange={(event) => field('welcome_description', event.target.value)} /></label>
    <label>Color theme<select value={theme} onChange={(event) => { const next = themes[event.target.value]; if (next) onChange({ ...draft, colors: { ...draft.colors, ...next.colors } }) }}><option value="rose">Warm rose</option><option value="forest">Forest green</option><option value="ocean">Ocean blue</option>{theme === 'custom' && <option value="custom">Existing custom colors</option>}</select></label>
    <label>Body font<select value={draft.typography.body} onChange={(event) => onChange({ ...draft, typography: { ...draft.typography, body: event.target.value } })}>{['inter', 'montserrat', 'nunito_sans', 'source_sans_3', 'system_sans'].map((font) => <option key={font} value={font}>{font.replaceAll('_', ' ')}</option>)}</select></label>
    <label>Heading font<select value={draft.typography.display} onChange={(event) => onChange({ ...draft, typography: { ...draft.typography, display: event.target.value } })}>{['cormorant_garamond', 'lora', 'merriweather', 'playfair_display', 'source_serif_4', 'system_serif'].map((font) => <option key={font} value={font}>{font.replaceAll('_', ' ')}</option>)}</select></label>
    <label>Support label<input maxLength={80} value={draft.support.label ?? ''} onChange={(event) => onChange({ ...draft, support: { ...draft.support, label: event.target.value || null } })} /></label>
    <label>Support email<input type="email" maxLength={254} value={draft.support.email ?? ''} onChange={(event) => onChange({ ...draft, support: { ...draft.support, email: event.target.value || null } })} /></label>
    <label className="program-wide">Support website<input type="url" maxLength={2048} pattern="https://.*" value={draft.support.url ?? ''} onChange={(event) => onChange({ ...draft, support: { ...draft.support, url: event.target.value || null } })} placeholder="https://…" /></label>
    <div className="program-wide"><details><summary>Logo, footer, and additional colors</summary><div className="program-fields program-advanced">
      <label className="program-wide">Logo image URL<input type="url" maxLength={2048} pattern="https://.*" value={draft.logo_url ?? ''} onChange={(event) => onChange({ ...draft, logo_url: event.target.value || null })} placeholder="https://…" /><small>Use an existing approved HTTPS image.</small></label>
      <label className="program-wide">Browser icon URL<input type="url" maxLength={2048} pattern="https://.*" value={draft.favicon_url ?? ''} onChange={(event) => onChange({ ...draft, favicon_url: event.target.value || null })} placeholder="https://…" /></label>
      <label>Platform attribution<input maxLength={80} value={draft.powered_by_name ?? ''} onChange={(event) => onChange({ ...draft, powered_by_name: event.target.value || null })} /></label>
      <label>Attribution placement<select value={draft.powered_by_placement} onChange={(event) => onChange({ ...draft, powered_by_placement: event.target.value as BrandConfig['powered_by_placement'] })}><option value="hidden">Hidden</option><option value="header">Header</option><option value="footer">Footer</option></select></label>
      <label className="program-wide">Footer message<textarea rows={3} maxLength={500} value={draft.footer.text ?? ''} onChange={(event) => onChange({ ...draft, footer: { ...draft.footer, text: event.target.value || null } })} /></label>
      <label>Privacy policy URL<input type="url" maxLength={2048} pattern="https://.*" value={draft.footer.privacy_url ?? ''} onChange={(event) => onChange({ ...draft, footer: { ...draft.footer, privacy_url: event.target.value || null } })} /></label>
      <label>Terms URL<input type="url" maxLength={2048} pattern="https://.*" value={draft.footer.terms_url ?? ''} onChange={(event) => onChange({ ...draft, footer: { ...draft.footer, terms_url: event.target.value || null } })} /></label>
      {Object.keys(draft.colors).map((key) => <label key={key}>{key.replaceAll('_', ' ')}<input type="color" value={draft.colors[key]} onChange={(event) => onChange({ ...draft, colors: { ...draft.colors, [key]: event.target.value } })} /></label>)}
      <p className="program-help program-wide">Colors must remain readable. Saving checks text, button, and focus contrast.</p>
    </div></details></div>
  </div>
}

function previewFont(name: string, display = false) {
  if (name === 'system_serif') return 'Georgia, "Times New Roman", serif'
  if (name === 'system_sans') return 'ui-sans-serif, system-ui, sans-serif'
  return `"${name.replaceAll('_', ' ')}", ${display ? 'Georgia, serif' : 'ui-sans-serif, system-ui, sans-serif'}`
}
function BrandWelcomePreview({ config }: { config: BrandConfig }) {
  return <article className="panel"><h3>Welcome screen preview</h3><p className="program-help">Preview only · the saved brand draft · desktop and phone widths</p><div className="program-preview" style={{ background: config.colors.background, color: config.colors.text, borderColor: config.colors.border, fontFamily: previewFont(config.typography.body) }}>
    <header style={{ borderColor: config.colors.border }}>{config.logo_url && <img src={config.logo_url} alt="" referrerPolicy="no-referrer" />}<strong>{config.short_name}</strong>{config.powered_by_placement === 'header' && config.powered_by_name && <small>Powered by {config.powered_by_name}</small>}</header>
    <div><p>{config.organization_name}</p><h4 style={{ fontFamily: previewFont(config.typography.display, true) }}>{config.welcome_heading || config.product_name}</h4><p>{config.welcome_description}</p><span className="program-preview-action" style={{ background: config.colors.primary, color: config.colors.on_primary }}>Get started</span><small>{config.tagline}</small></div>
    <footer style={{ color: config.colors.text_muted, borderColor: config.colors.border }}>{config.support.label && <p>{config.support.label}{config.support.email ? ` · ${config.support.email}` : ''}</p>}<p>{config.footer.text}</p>{config.powered_by_placement === 'footer' && config.powered_by_name && <small>Powered by {config.powered_by_name}</small>}</footer>
  </div></article>
}
