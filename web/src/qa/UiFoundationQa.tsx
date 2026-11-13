import { useRef, useState, type CSSProperties } from 'react'
import { createRoot } from 'react-dom/client'
import { selectChevron } from '../lib/selectChevron'
import { brandDeep } from '../lib/brandDeep'
import { dialogExit } from '../lib/dialogExit'
import { usePilotDialog } from '../lib/usePilotDialog'
import '../styles/tokens.css'
import '../index.css'
import '../appStyles'
import '../dialogViewport.css'
import './UiFoundationQa.css'

const css = (values: Record<string, string | number>) => values as CSSProperties
const blue = css({
  '--select-chevron': selectChevron('#4d5c6e'), '--emerald': '#1f3a5f', '--berry': '#142c49', '--emerald-soft': '#e4edf6', '--gold': '#a66342',
  '--cream': '#f2f5f9', '--paper': '#ffffff', '--line': '#d5dfeb', '--muted': '#4d5c6e', '--ink': '#172435',
  '--brand-on-primary': '#ffffff', '--brand-focus': '#1f3a5f', '--status-green': '#42694f',
  '--font-display': 'Georgia, serif', '--font-body': 'ui-sans-serif, system-ui, sans-serif',
  ...brandDeep('#1f3a5f', '#f2f5f9'),
})
const plum = css(brandDeep('#7b4a58', '#f7f2ea'))
const months = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D']
const amounts = months.map((_, index) => index === 10 ? 2180 : index === 11 ? 680 : index >= 7 ? 1400 : 850)
const values = amounts.map(amount => amount / Math.max(...amounts) * 100)
const Chevron = () => <svg className="ui-row__chevron" aria-hidden="true" viewBox="0 0 16 16"><path d="m6 4 4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.5" /></svg>

function BrandPrimitives({ name, theme, id }: { name: string; theme: CSSProperties; id: string }) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [selected, setSelected] = useState(false)
  return <section className="ui-brand qa-brand" style={theme} aria-label={name}>
    <header><p className="ui-label">{name} · fictional preview</p><h1 className="ui-title">November</h1><p className="qa-subtitle">A little more room for what matters.</p></header>
    <section className="ui-answer" aria-label="This month’s answer">
      <div className="ui-label">What’s left this month</div><p className="ui-figure">$2,180</p><p className="ui-answer__note">Your plan, not your bank balance</p>
      <div className="ui-bar" style={css({ '--spent': '26%', '--planned': '39%' })} aria-hidden="true"><span className="ui-bar__spent" /><span className="ui-bar__planned" /><span className="ui-bar__remainder" /></div>
      <div className="ui-key"><span><i className="ui-dot ui-dot--spent" aria-hidden="true" />Spent<strong>$1,612</strong></span><span><i className="ui-dot ui-dot--planned" aria-hidden="true" />Still planned<strong>$2,408</strong></span><span><i className="ui-dot ui-dot--remainder" aria-hidden="true" />Money in<strong>$6,200</strong></span></div>
    </section>
    <section className="ui-card"><h2 className="ui-section">Needs you</h2><div className="ui-rows">
      <a className="ui-row" href="#controls"><span className="ui-dot" aria-hidden="true" /><span className="ui-row__body"><span className="ui-row__title">2 purchases to check</span><span className="ui-row__detail">Payless · $53.40 and 1 more</span></span><Chevron /></a>
      <button className="ui-row" onClick={() => dialog.current?.showModal()}><span className="ui-dot ui-dot--good" aria-hidden="true" /><span className="ui-row__body"><span className="ui-row__title">Breathing room</span><span className="ui-row__detail">2.5 of 6 months of planned costs</span></span><span className="ui-row__trailing">View</span><Chevron /></button>
      <div className="ui-row"><span className="ui-monogram" aria-hidden="true">M</span><span className="ui-row__body"><span className="ui-row__title">Ask Mia</span><span className="ui-row__detail">Tell her what changed. You approve it.</span></span></div>
      <button className="ui-row" disabled><span className="ui-dot ui-dot--neutral" aria-hidden="true" /><span className="ui-row__body">Nothing else to review</span><Chevron /></button>
    </div></section>
    <section className="ui-card"><div className="ui-section"><h2>Your year</h2><a href="#controls">See the plan</a></div>
      <ol className="ui-cols" aria-label="Monthly planned remainder">{months.map((month, index) => <li className={`ui-cols__column${index === 10 ? ' ui-cols__column--current' : index === 11 ? ' ui-cols__column--attention' : ''}`} key={index} aria-label={`${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][index]}: $${amounts[index].toLocaleString('en-US')}${index === 10 ? ', current month' : index === 11 ? ', tight month' : ''}`}><span className="ui-cols__bar" style={css({ '--value': `${values[index]}%` })} aria-hidden="true" /><span className="ui-cols__label" aria-hidden="true">{month}</span></li>)}</ol>
      <p className="qa-chart-note"><strong>December is your tight month.</strong> $680 left after planned costs.</p>
      <h3 className="ui-section">Breathing room</h3><div className="ui-track" aria-hidden="true" style={css({ '--value': '42%' })}><span className="ui-track__fill" /><span className="ui-track__goal" /></div><p className="qa-chart-note">Your cushion covers 2.5 of 6 months of planned costs.</p>
      <div className="ui-bar" aria-hidden="true" style={css({ '--spent': '26%', '--planned': '39%' })}><span className="ui-bar__spent" /><span className="ui-bar__planned" /><span className="ui-bar__remainder" /></div><div className="ui-key"><span><i className="ui-dot ui-dot--spent" aria-hidden="true" />Spent $1,612</span><span><i className="ui-dot ui-dot--planned" aria-hidden="true" />Planned $2,408</span><span><i className="ui-dot ui-dot--remainder" aria-hidden="true" />Left $2,180</span></div><p className="qa-chart-note">Confirmed purchases use 26% of this month’s income.</p>
    </section>
    <section className="ui-card"><h2 className="ui-section">Actions and status</h2><div className="qa-actions">
      <button className="ui-btn ui-btn--primary">Confirm purchase</button><button className="ui-btn ui-btn--tonal">Change</button><button className="ui-btn ui-btn--text">Not now</button>
      <button className="ui-btn ui-btn--primary" disabled>Confirm purchase</button><button className="ui-btn ui-btn--tonal" disabled>Change</button><button className="ui-btn ui-btn--text" disabled>Not now</button>
      <button className="ui-chip" aria-pressed={selected} onClick={() => setSelected(!selected)}>This month</button><button className="ui-chip" disabled>Next month</button>
      <span className="ui-pill"><i className="ui-dot ui-dot--neutral" aria-hidden="true" />Not started</span><span className="ui-pill ui-pill--good"><i className="ui-dot ui-dot--good" aria-hidden="true" />Checked in</span><span className="ui-pill ui-pill--attention"><i className="ui-dot ui-dot--attention" aria-hidden="true" />Needs you</span>
    </div><button className="ui-btn ui-btn--tonal ui-btn--full" onClick={() => dialog.current?.showModal()}>Open preview dialog</button></section>
    <section className="ui-card" id={id === 'plum' ? 'controls' : undefined}><h2 className="ui-section">Native controls</h2><form className="qa-fields" onSubmit={event => event.preventDefault()}>
      <label>Merchant<input className="ui-field" defaultValue="Payless" /></label><label>Category<select className="ui-select" defaultValue="groceries"><option value="groceries">Groceries and household essentials</option><option>Transport</option></select></label>
      <label>Amount<input type="number" defaultValue="53.40" step="0.01" /></label><label>Purchase date<input type="date" defaultValue="2026-11-13" /></label><label>Note<textarea className="ui-field" defaultValue="For the week ahead" /></label>
      <label className="ui-check"><input className="ui-check__input" type="checkbox" defaultChecked />I reviewed this purchase</label><label className="ui-check"><input type="checkbox" />Remind me later</label><label className="ui-check"><input type="checkbox" disabled />Reminder unavailable</label>
      <label className="ui-check"><input type="radio" name={`${id}-period`} />This month</label><label className="ui-check"><input type="radio" name={`${id}-period`} />Next month</label>
      <label>Unavailable category<select disabled><option>Choose a category</option></select></label>
      <details className="ui-disclosure"><summary>How this is counted</summary><p>Only purchases you confirm count as spent.</p></details><details open><summary>What stays private</summary><p>Your records start private. You choose what to share.</p></details>
      <div className="qa-actions"><button className="button button--primary">Legacy primary</button><button className="primary-button" disabled>Legacy disabled</button><button className="secondary-button">Legacy tonal</button><button className="danger-button">Legacy danger</button><button className="text-button">Legacy text</button></div>
    </form></section>
    <dialog ref={dialog} className="qa-native-dialog ui-card" data-dialog-panel="true" aria-labelledby={`${id}-dialog-title`} onCancel={event => { event.preventDefault(); dialogExit(dialog.current, () => dialog.current?.close()) }}>
      <h2 id={`${id}-dialog-title`}>A little breathing room</h2><p>Your cushion covers 2.5 months of planned costs.</p><button className="ui-btn ui-btn--primary" onClick={() => dialogExit(dialog.current, () => dialog.current?.close())}>Close preview dialog</button>
    </dialog>
  </section>
}

function ExitProbe({ onClose, privatePanel }: { onClose: () => void; privatePanel: boolean }) {
  const { dialogRef, requestClose } = usePilotDialog(onClose)
  return <div className="pilot-dialog-overlay" data-dialog-surface="true"><button className="pilot-dialog-backdrop" tabIndex={-1} aria-hidden="true" onClick={requestClose} /><section className="pilot-dialog ui-card" ref={dialogRef} role="dialog" aria-label="Dismissal preview" tabIndex={-1} data-dialog-panel="true" data-dialog-private={privatePanel || undefined}>
    <h2 className="ui-title">Keep your place</h2><p>Fictional preview. Closing releases the page immediately.</p>
    <label>Correction<textarea className="ui-field" defaultValue="For the week ahead" /></label>
    <div className="qa-exit-scroll">{Array.from({ length: 12 }, (_, index) => <p key={index}>Fictional row {index + 1}</p>)}</div>
    <button className="ui-btn ui-btn--tonal" onClick={requestClose}>Dismiss preview</button>
  </section></div>
}
function ExitPreview() {
  const [open, setOpen] = useState(false), [privatePanel, setPrivate] = useState(false), [clicks, setClicks] = useState(0)
  return <section className="ui-card qa-exit-preview"><button className="ui-btn ui-btn--tonal" onClick={() => { setPrivate(false); setOpen(true) }}>Open dismissal preview</button><button className="ui-btn ui-btn--tonal" onClick={() => { setPrivate(true); setOpen(true) }}>Open private preview</button><button className="ui-btn ui-btn--text" onClick={() => setClicks(value => value + 1)}>Page action {clicks}</button><input className="ui-field" aria-label="Page draft" />{open && <ExitProbe onClose={() => setOpen(false)} privatePanel={privatePanel} />}</section>
}

export function UiFoundationQa() {
  return <main className="qa-foundation"><header className="qa-heading"><p className="ui-label">Development QA · synthetic data</p><h1 className="ui-title">The shared foundation</h1><p>Two brands. The same controls, rhythm and care.</p></header><ExitPreview /><div className="qa-brands"><BrandPrimitives name="Household CFO" id="plum" theme={plum} /><BrandPrimitives name="Blue coach" id="blue" theme={blue} /></div></main>
}

if (import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true') createRoot(document.getElementById('root')!).render(<UiFoundationQa />)
