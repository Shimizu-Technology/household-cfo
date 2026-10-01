import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import {
  ApiRequestError,
  approveAdminContentItem,
  createAdminContentItem,
  createAdminContentPack,
  fetchAdminContentItems,
  fetchAdminContentPacks,
  publishAdminContentPack,
  updateAdminContentItem,
  updateAdminContentPack,
  updateAdminPersonaContentPacks,
} from '../api'
import type {
  AdminContentItem,
  AdminContentItemKind,
  AdminContentPack,
  AdminContentPackKind,
  AdminContentScope,
  AdminPersonaDetail,
  CurrentUser,
} from '../api'
import { Button } from './Button'
import './CoachContentLibrary.css'

const itemKinds: AdminContentItemKind[] = ['guidance', 'script', 'example', 'phrase', 'culture', 'finance_reference']
const packKinds: AdminContentPackKind[] = ['voice_culture', 'coaching_method', 'finance_reference']
const normalizeSingleLine = (value: string) => value.trim().replace(/\s+/g, ' ')

export function CoachContentLibrary({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange?: (dirty: boolean) => void }) {
  const [items, setItems] = useState<AdminContentItem[]>([])
  const [packs, setPacks] = useState<AdminContentPack[]>([])
  const [selectedItemId, setSelectedItemId] = useState<number | null>(null)
  const [selectedPackId, setSelectedPackId] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [itemDirty, setItemDirty] = useState(false)
  const [packDirty, setPackDirty] = useState(false)

  useEffect(() => onDirtyChange?.(itemDirty || packDirty), [itemDirty, onDirtyChange, packDirty])
  useEffect(() => () => onDirtyChange?.(false), [onDirtyChange])

  const load = useCallback(async () => {
    setBusy(true)
    setError(null)
    try {
      const [nextItems, nextPacks] = await Promise.all([fetchAdminContentItems(), fetchAdminContentPacks()])
      setItems(nextItems)
      setPacks(nextPacks)
    } catch (caught) {
      setError(errorMessage(caught, 'The coaching library could not load.'))
    } finally {
      setBusy(false)
    }
  }, [])

  useEffect(() => { queueMicrotask(() => void load()) }, [load])

  async function mutate(action: () => Promise<void>, success: string): Promise<boolean> {
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      await action()
      await load()
      setNotice(success)
      return true
    } catch (caught) {
      setError(errorMessage(caught, 'That change could not be saved.'))
      return false
    } finally {
      setBusy(false)
    }
  }

  const selectedItem = items.find((item) => item.id === selectedItemId) ?? null
  const selectedPack = packs.find((pack) => pack.id === selectedPackId) ?? null

  return (
    <section className="coach-content-library" aria-busy={busy}>
      {error && <div className="coach-content-alert is-error" role="alert"><span>{error}</span><button type="button" onClick={() => void load()}>Retry</button></div>}
      {notice && <p className="coach-content-alert is-success" role="status">{notice}</p>}

      <div className="coach-content-explainer panel">
        <div>
          <p className="eyebrow">Approved teaching only</p>
          <h3>Build reusable coaching material</h3>
        </div>
        <p>Write the coach's real guidance, approve a fixed version, then publish it inside a pack. Assistants use only the exact pack versions you attach and publish.</p>
        <ul>
          <li>Location labels never create slang, accents, or cultural assumptions.</li>
          <li>New versions stay pending until you choose and republish them.</li>
          <li>Content shapes coaching and wording. It cannot change financial records or approvals.</li>
        </ul>
      </div>

      <div className="coach-content-grid">
        <ContentItemsPanel
          currentUser={currentUser}
          items={items}
          selected={selectedItem}
          busy={busy}
          onDirtyChange={setItemDirty}
          onSelect={setSelectedItemId}
          onCreate={(values) => mutate(async () => { const item = await createAdminContentItem(values); setSelectedItemId(item.id) }, 'Content draft created. Approve it when the wording is ready.')}
          onSave={(item, values) => mutate(async () => { await updateAdminContentItem(item.id, { ...values, draft_revision: item.draft_revision ?? 0 }) }, 'Content draft saved. Approve the new version when it is ready.')}
          onApprove={(item) => mutate(async () => { await approveAdminContentItem(item.id, item.draft_revision ?? 0, item.draft_digest ?? '') }, `${item.title} is approved as an immutable version.`)}
        />
        <ContentPacksPanel
          currentUser={currentUser}
          packs={packs}
          items={items}
          selected={selectedPack}
          busy={busy}
          onDirtyChange={setPackDirty}
          onSelect={setSelectedPackId}
          onCreate={(values) => mutate(async () => { const pack = await createAdminContentPack(values); setSelectedPackId(pack.id) }, 'Content pack draft created. Publish it when its item versions are correct.')}
          onSave={(pack, values) => mutate(async () => { await updateAdminContentPack(pack.id, { ...values, draft_revision: pack.draft_revision ?? 0 }) }, 'Pack draft saved. Its published version has not changed.')}
          onPublish={(pack) => mutate(async () => { await publishAdminContentPack(pack.id, { draft_revision: pack.draft_revision ?? 0, draft_manifest_digest: pack.draft_manifest_digest ?? '', expected_published_version_id: pack.current_published_version?.id ?? null }) }, `${pack.name} is published as an immutable version.`)}
        />
      </div>
    </section>
  )
}

function ContentItemsPanel({ currentUser, items, selected, busy, onDirtyChange, onSelect, onCreate, onSave, onApprove }: {
  currentUser: CurrentUser
  items: AdminContentItem[]
  selected: AdminContentItem | null
  busy: boolean
  onDirtyChange: (dirty: boolean) => void
  onSelect: (id: number | null) => void
  onCreate: (values: { title: string; scope: AdminContentScope; kind: AdminContentItemKind; draft_content: string; always_on: boolean }) => Promise<boolean>
  onSave: (item: AdminContentItem, values: { title: string; kind: AdminContentItemKind; draft_content: string; always_on: boolean }) => Promise<boolean>
  onApprove: (item: AdminContentItem) => Promise<boolean>
}) {
  const [creating, setCreating] = useState(false)
  const [title, setTitle] = useState('')
  const [content, setContent] = useState('')
  const [kind, setKind] = useState<AdminContentItemKind>('guidance')
  const [scope, setScope] = useState<AdminContentScope>('coach')
  const [alwaysOn, setAlwaysOn] = useState(false)
  const itemDirty = Boolean(selected?.editable && (
    normalizeSingleLine(title) !== selected.title ||
    content.trim() !== (selected.draft_content ?? '') ||
    kind !== selected.kind ||
    alwaysOn !== selected.always_on
  ))
  const createDirty = Boolean(creating && (title.trim() || content.trim() || kind !== 'guidance' || scope !== 'coach' || alwaysOn))

  useEffect(() => onDirtyChange(itemDirty || createDirty), [createDirty, itemDirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  function startCreate() {
    onSelect(null)
    setCreating(true)
    setTitle('')
    setContent('')
    setKind('guidance')
    setScope('coach')
    setAlwaysOn(false)
  }

  function selectItem(item: AdminContentItem) {
    setCreating(false)
    setTitle(item.title)
    setContent(item.editable ? item.draft_content ?? '' : item.current_approved_version?.content ?? '')
    setKind(item.kind)
    setScope(item.scope)
    setAlwaysOn(item.always_on)
    onSelect(item.id)
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    const normalizedTitle = normalizeSingleLine(title)
    const normalizedContent = content.trim()
    const succeeded = selected
      ? await onSave(selected, { title: normalizedTitle, kind, draft_content: normalizedContent, always_on: alwaysOn })
      : await onCreate({ title: normalizedTitle, scope, kind, draft_content: normalizedContent, always_on: alwaysOn })
    if (succeeded) {
      setTitle(normalizedTitle)
      setContent(normalizedContent)
      setCreating(false)
    }
  }

  return (
    <article className="panel coach-content-panel">
      <header><div><p className="eyebrow">1 · Content items</p><h3>Coach-authored building blocks</h3></div><Button size="compact" disabled={busy} onClick={startCreate}>New item</Button></header>
      <div className="coach-content-list" aria-label="Content items">
        {items.length === 0 && <p className="coach-content-empty">No approved teaching yet. Start with one short piece of guidance.</p>}
        {items.map((item) => (
          <button type="button" disabled={busy} key={item.id} className={selected?.id === item.id ? 'is-selected' : ''} onClick={() => selectItem(item)}>
            <span><strong>{item.title}</strong><small>{label(item.kind)}</small></span>
            <small>{item.current_approved_version ? `Approved v${item.current_approved_version.version}` : 'Draft only'}{item.has_unapproved_changes ? ' · Changes waiting' : ''}</small>
          </button>
        ))}
      </div>
      {(creating || selected) && (
        <form className="coach-content-form" onSubmit={(event) => void submit(event)}>
          <label><span>Title</span><input required disabled={busy || Boolean(selected && !selected.editable)} maxLength={160} value={title} onChange={(event) => setTitle(event.target.value)} /></label>
          <div className="coach-content-form-row">
            <label><span>Type</span><select disabled={busy || Boolean(selected && !selected.editable)} value={kind} onChange={(event) => setKind(event.target.value as AdminContentItemKind)}>{itemKinds.map((value) => <option value={value} key={value}>{label(value)}</option>)}</select></label>
            <label><span>Owner</span><select disabled={busy || Boolean(selected) || !currentUser.is_admin} value={scope} onChange={(event) => setScope(event.target.value as AdminContentScope)}><option value="coach">My coaching library</option>{currentUser.is_admin && <option value="platform">Platform library</option>}</select></label>
          </div>
          <label><span>Draft wording</span><textarea required disabled={busy || Boolean(selected && !selected.editable)} rows={8} maxLength={10000} value={content} onChange={(event) => setContent(event.target.value)} placeholder="Write the exact teaching, phrase, example, or cultural context Mia may use." /><small>{content.length.toLocaleString()} / 10,000 characters</small></label>
          <label className="coach-content-always-on"><input type="checkbox" disabled={busy || Boolean(selected && !selected.editable)} checked={alwaysOn} onChange={(event) => setAlwaysOn(event.target.checked)} /><span><strong>Supply for every question</strong><small>Use sparingly for foundational guidance that is relevant in every conversation.</small></span></label>
          <div className="coach-content-actions">
            {(!selected || selected.editable) && <Button type="submit" disabled={busy || !title.trim() || !content.trim() || Boolean(selected && !itemDirty)}>{selected ? 'Save draft' : 'Create draft'}</Button>}
            {selected?.editable && <Button type="button" variant="secondary" disabled={busy || itemDirty || !selected.has_unapproved_changes} onClick={() => void onApprove(selected)}>{itemDirty ? 'Save draft before approving' : selected.has_unapproved_changes ? 'Approve new version' : `Approved v${selected.current_approved_version?.version}`}</Button>}
          </div>
          {selected && !selected.editable && <p className="coach-content-note">Platform content is visible for use and can be changed only by an administrator.</p>}
        </form>
      )}
    </article>
  )
}

function ContentPacksPanel({ currentUser, packs, items, selected, busy, onDirtyChange, onSelect, onCreate, onSave, onPublish }: {
  currentUser: CurrentUser
  packs: AdminContentPack[]
  items: AdminContentItem[]
  selected: AdminContentPack | null
  busy: boolean
  onDirtyChange: (dirty: boolean) => void
  onSelect: (id: number | null) => void
  onCreate: (values: { name: string; description: string; scope: AdminContentScope; pack_kind: AdminContentPackKind; item_version_ids: number[] }) => Promise<boolean>
  onSave: (pack: AdminContentPack, values: { name: string; description: string; pack_kind: AdminContentPackKind; item_version_ids: number[] }) => Promise<boolean>
  onPublish: (pack: AdminContentPack) => Promise<boolean>
}) {
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [kind, setKind] = useState<AdminContentPackKind>('coaching_method')
  const [scope, setScope] = useState<AdminContentScope>('coach')
  const [selectedVersions, setSelectedVersions] = useState<number[]>([])
  const approvedItems = items.filter((item) => item.current_approved_version && !item.archived && (scope === 'coach' || item.scope === 'platform'))
  const packDirty = Boolean(selected?.editable && (
    normalizeSingleLine(name) !== selected.name ||
    description.trim() !== selected.description ||
    kind !== selected.pack_kind ||
    selectedVersions.join(',') !== selected.draft_items.map((item) => item.id).join(',')
  ))
  const createDirty = Boolean(creating && (name.trim() || description.trim() || kind !== 'coaching_method' || scope !== 'coach' || selectedVersions.length > 0))

  useEffect(() => onDirtyChange(packDirty || createDirty), [createDirty, onDirtyChange, packDirty])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  function startCreate() {
    onSelect(null)
    setCreating(true)
    setName('')
    setDescription('')
    setKind('coaching_method')
    setScope('coach')
    setSelectedVersions([])
  }

  function selectPack(pack: AdminContentPack) {
    setCreating(false)
    setName(pack.name)
    setDescription(pack.description)
    setKind(pack.pack_kind)
    setScope(pack.scope)
    setSelectedVersions(pack.draft_items.map((item) => item.id))
    onSelect(pack.id)
  }

  function toggleItem(item: AdminContentItem) {
    const version = item.current_approved_version
    if (!version) return
    setSelectedVersions((current) => {
      const versionsForItem = selected?.draft_items.filter((candidate) => candidate.item_id === item.id).map((candidate) => candidate.id) ?? []
      const withoutItem = current.filter((id) => !versionsForItem.includes(id) && id !== version.id)
      const included = current.includes(version.id) || versionsForItem.some((id) => current.includes(id))
      return included ? withoutItem : [...withoutItem, version.id]
    })
  }

  function upgradeItem(item: AdminContentItem) {
    const version = item.current_approved_version
    if (!version) return
    const oldIds = selected?.draft_items.filter((candidate) => candidate.item_id === item.id).map((candidate) => candidate.id) ?? []
    setSelectedVersions((current) => [...current.filter((id) => !oldIds.includes(id) && id !== version.id), version.id])
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    const normalizedName = normalizeSingleLine(name)
    const normalizedDescription = description.trim()
    const values = { name: normalizedName, description: normalizedDescription, pack_kind: kind, item_version_ids: selectedVersions }
    const succeeded = selected ? await onSave(selected, values) : await onCreate({ ...values, scope })
    if (succeeded) {
      setName(normalizedName)
      setDescription(normalizedDescription)
      setCreating(false)
    }
  }

  return (
    <article className="panel coach-content-panel">
      <header><div><p className="eyebrow">2 · Content packs</p><h3>Publish a reusable collection</h3></div><Button size="compact" disabled={busy} onClick={startCreate}>New pack</Button></header>
      <div className="coach-content-list" aria-label="Content packs">
        {packs.length === 0 && <p className="coach-content-empty">Create a pack after approving at least one content item.</p>}
        {packs.map((pack) => (
          <button type="button" disabled={busy} key={pack.id} className={selected?.id === pack.id ? 'is-selected' : ''} onClick={() => selectPack(pack)}>
            <span><strong>{pack.name}</strong><small>{label(pack.pack_kind)}</small></span>
            <small>{pack.current_published_version ? `Published v${pack.current_published_version.version}` : 'Draft only'}{pack.update_available ? ' · Update available' : ''}</small>
          </button>
        ))}
      </div>
      {(creating || selected) && (
        <form className="coach-content-form" onSubmit={(event) => void submit(event)}>
          <label><span>Pack name</span><input required disabled={busy || Boolean(selected && !selected.editable)} maxLength={160} value={name} onChange={(event) => setName(event.target.value)} /></label>
          <label><span>Description</span><textarea disabled={busy || Boolean(selected && !selected.editable)} rows={2} maxLength={2000} value={description} onChange={(event) => setDescription(event.target.value)} /></label>
          <div className="coach-content-form-row">
            <label><span>Purpose</span><select disabled={busy || Boolean(selected && !selected.editable)} value={kind} onChange={(event) => setKind(event.target.value as AdminContentPackKind)}>{packKinds.map((value) => <option value={value} key={value}>{label(value)}</option>)}</select></label>
            <label><span>Owner</span><select disabled={busy || Boolean(selected) || !currentUser.is_admin} value={scope} onChange={(event) => { const nextScope = event.target.value as AdminContentScope; setScope(nextScope); if (nextScope === 'platform') setSelectedVersions((current) => current.filter((id) => items.some((item) => item.scope === 'platform' && item.current_approved_version?.id === id))) }}><option value="coach">My coaching library</option>{currentUser.is_admin && <option value="platform">Platform library</option>}</select></label>
          </div>
          <fieldset className="coach-content-checklist"><legend>Exact approved item versions</legend>
            {approvedItems.map((item) => {
              const current = item.current_approved_version!
              const pinned = selected?.draft_items.find((candidate) => candidate.item_id === item.id)
              const included = selectedVersions.includes(current.id) || Boolean(pinned && selectedVersions.includes(pinned.id))
              const updateAvailable = Boolean(pinned && pinned.id !== current.id && !selectedVersions.includes(current.id))
              return <div className="coach-content-item-option" key={item.id}><label><input type="checkbox" disabled={busy || Boolean(selected && !selected.editable)} checked={included} onChange={() => toggleItem(item)} /><span><strong>{item.title}</strong><small>{updateAvailable ? `Pinned v${pinned?.version} · current v${current.version}` : `v${current.version}`}</small></span></label>{updateAvailable && selected?.editable && <button type="button" className="coach-content-upgrade" disabled={busy} onClick={() => upgradeItem(item)}>Use v{current.version}</button>}</div>
            })}
          </fieldset>
          <div className="coach-content-actions">
            {(!selected || selected.editable) && <Button type="submit" disabled={busy || !name.trim() || selectedVersions.length === 0 || Boolean(selected && !packDirty)}>{selected ? 'Save pack' : 'Create pack draft'}</Button>}
            {selected?.editable && <Button type="button" variant="secondary" disabled={busy || packDirty || !selected.has_unpublished_changes || selected.draft_items.length === 0} onClick={() => void onPublish(selected)}>{packDirty ? 'Save pack before publishing' : selected.has_unpublished_changes ? 'Publish exact version' : `Published v${selected.current_published_version?.version}`}</Button>}
          </div>
          <p className="coach-content-note">Publishing creates a fixed snapshot. Later item edits never change a published pack or an assigned assistant automatically.</p>
        </form>
      )}
    </article>
  )
}

export function PersonaContentPacksPanel({ persona, dirty, onDirtyChange, onPersonaChange }: {
  persona: AdminPersonaDetail
  dirty: boolean
  onDirtyChange: (dirty: boolean) => void
  onPersonaChange: (persona: AdminPersonaDetail) => void
}) {
  const [packs, setPacks] = useState<AdminContentPack[]>([])
  const [selectedIds, setSelectedIds] = useState<number[]>(persona.content_packs?.map((pack) => pack.id) ?? [])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    void fetchAdminContentPacks().then(setPacks).catch((caught) => setError(errorMessage(caught, 'Content packs could not load.')))
  }, [persona.id])

  const published = useMemo(() => packs.filter((pack) => pack.current_published_version && !pack.archived), [packs])

  function updateSelection(next: number[]) {
    setSelectedIds(next)
    onDirtyChange(next.join(',') !== (persona.content_packs?.map((pack) => pack.id) ?? []).join(','))
  }

  function toggle(pack: AdminContentPack) {
    const version = pack.current_published_version
    if (!version) return
    const linkedForPack = persona.content_packs?.filter((candidate) => candidate.pack_id === pack.id).map((candidate) => candidate.id) ?? []
    const withoutPack = selectedIds.filter((id) => !linkedForPack.includes(id) && id !== version.id)
    const included = selectedIds.includes(version.id) || linkedForPack.some((id) => selectedIds.includes(id))
    updateSelection(included ? withoutPack : [...withoutPack, version.id])
  }

  function chooseCurrentVersion(pack: AdminContentPack) {
    const version = pack.current_published_version
    if (!version) return
    const linkedForPack = persona.content_packs?.filter((candidate) => candidate.pack_id === pack.id).map((candidate) => candidate.id) ?? []
    updateSelection([...selectedIds.filter((id) => !linkedForPack.includes(id) && id !== version.id), version.id])
  }

  const changed = selectedIds.join(',') !== (persona.content_packs?.map((pack) => pack.id) ?? []).join(',')

  useEffect(() => onDirtyChange(changed), [changed, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  async function save() {
    setBusy(true)
    setError(null)
    try {
      const next = await updateAdminPersonaContentPacks(persona.id, persona.draft_revision ?? 0, selectedIds)
      onPersonaChange(next)
    } catch (caught) {
      setError(errorMessage(caught, 'The content selection could not be saved.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <article className="panel persona-content-packs">
      <header><div><p className="eyebrow">Approved coaching library</p><h3>Choose exact content pack versions</h3><p>These sources can shape Mia's wording and coaching method after the financial answer is verified.</p></div></header>
      {error && <p className="coach-content-alert is-error" role="alert">{error}</p>}
      {published.length === 0 ? <p className="coach-content-empty">Publish a content pack in Coaching Library, then return here to attach it.</p> : (
        <div className="persona-pack-options">
          {published.map((pack) => {
            const current = pack.current_published_version!
            const attached = persona.content_packs?.find((candidate) => candidate.pack_id === pack.id)
            const included = selectedIds.includes(current.id) || Boolean(attached && selectedIds.includes(attached.id))
            const updateAvailable = Boolean(attached && attached.id !== current.id && !selectedIds.includes(current.id))
            return <div className="persona-pack-option" key={pack.id}><label><input type="checkbox" disabled={!persona.permissions.edit || dirty || busy} checked={included} onChange={() => toggle(pack)} /><span><strong>{pack.name}</strong><small>{label(pack.pack_kind)} · {updateAvailable ? `assistant uses v${attached?.version}, current v${current.version}` : `v${current.version}`}</small></span></label>{updateAvailable && persona.permissions.edit && <button type="button" className="coach-content-upgrade" disabled={dirty || busy} onClick={() => chooseCurrentVersion(pack)}>Use v{current.version}</button>}</div>
          })}
        </div>
      )}
      <div className="coach-content-actions"><Button disabled={!changed || dirty || busy || !persona.permissions.edit} onClick={() => void save()}>{busy ? 'Saving sources' : 'Save source selection'}</Button><small>{dirty ? 'Save persona fields before changing sources.' : 'Saving sources creates a new persona draft revision and requires a fresh preview.'}</small></div>
    </article>
  )
}

function label(value: string) {
  return value.replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase())
}

function errorMessage(caught: unknown, fallback: string) {
  if (caught instanceof ApiRequestError) return caught.message
  if (caught instanceof Error && caught.message) return caught.message
  return fallback
}
