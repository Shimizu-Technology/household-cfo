import { useEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { usePilotDialog } from '../lib/usePilotDialog'
import './MiaAssistPanels.css'

type Prompt = { label: string; message: string }
type Props = {
  panel: 'context' | 'prompts' | null
  onClose: () => void
  assistantName: string
  modal?: boolean
  contextSummary: string
  setupContent?: ReactNode
  pendingCount: number
  processingCount: number
  latestSource?: string
  realWorkspace: boolean
  uploading: boolean
  hasMessages: boolean
  busy: boolean
  onAttach: () => void
  onReviewImports: () => void
  onGuide: () => void
  onFeedback: () => void
  onClearChat: () => void
  onStartOver?: () => void
  updatePrompts: Prompt[]
  questionPrompts: Prompt[]
  onChoosePrompt: (message: string) => void
}

/** One controlled surface: mobile modal sheet, desktop companion to the conversation. */
export function MiaAssistPanels(props: Props) {
  const [compact, setCompact] = useState(() => window.matchMedia('(max-width: 999px)').matches)
  useEffect(() => {
    const media = window.matchMedia('(max-width: 999px)')
    const update = () => setCompact(media.matches)
    media.addEventListener('change', update)
    return () => media.removeEventListener('change', update)
  }, [])
  if (!props.panel) return null
  return compact || props.modal
    ? <ModalPanel key={props.panel} {...props} />
    : <CompanionPanel key={props.panel} {...props} />
}

function PanelContent(props: Props) {
  const act = (callback: () => void) => { props.onClose(); callback() }
  const choose = (message: string) => act(() => props.onChoosePrompt(message))
  return <>
    <header className="mia-assist-header">
      <div><span className="eyebrow">Ask {props.assistantName}</span><h2 id="mia-assist-title">{props.panel === 'prompts' ? 'What would you like to do?' : 'Context & help'}</h2></div>
      <button type="button" className="secondary-button" onClick={props.onClose}>Close</button>
    </header>
    <div className="mia-assist-body">
      {props.panel === 'prompts' ? <>
        <p className="mia-assist-intro">Choose a starting point, edit your message, then Send. Changes always need your review.</p>
        {[{ title: 'Update my information', prompts: props.updatePrompts }, { title: 'Ask a question', prompts: props.questionPrompts }].map(group => <section className="mia-assist-section" key={group.title} aria-label={group.title}>
          <h3>{group.title}</h3>
          <div className="mia-assist-prompts">{group.prompts.map(prompt => <button type="button" className="secondary-button" key={prompt.message} disabled={props.busy} onClick={() => choose(prompt.message)}>{prompt.label}</button>)}</div>
        </section>)}
      </> : <>
        <section className="mia-assist-section" aria-label="Your saved picture">
          <h3>Your saved picture</h3><p>{props.contextSummary}</p>
          {props.setupContent}
          <p className="mia-assist-note">Ask {props.assistantName} what is saved or what is missing. You review changes before applying them.</p>
        </section>
        <section className="mia-assist-section" aria-label="Files to review">
          <h3>Files to review</h3>
          {props.realWorkspace ? <>
            <dl className="mia-assist-status"><div><dt>Waiting for review</dt><dd>{props.pendingCount}</dd></div><div><dt>Processing</dt><dd>{props.processingCount}</dd></div></dl>
            <p>{props.latestSource || 'No approved file sources yet. Uploading a file does not update your numbers until you review and apply it.'}</p>
            <div className="mia-assist-actions"><button type="button" className="secondary-button" disabled={props.uploading || props.busy} onClick={() => act(props.onAttach)}>{props.uploading ? 'Uploading privately' : 'Attach a file'}</button><button type="button" className="secondary-button" onClick={() => act(props.onReviewImports)}>Review files</button></div>
            <details className="mia-assist-file-help"><summary>Supported files and sizes</summary><p>Attach up to five files. Images and PDFs up to 12 MB each; CSV, Excel and Word up to 20 MB each. Choose the file types and tell {props.assistantName} what you want reviewed.</p></details>
          </> : <p>Sign in to upload and review your own files.</p>}
        </section>
        {props.realWorkspace && <section className="mia-assist-section" aria-label="Help"><h3>Help</h3><div className="mia-assist-actions"><button type="button" className="secondary-button" onClick={() => act(props.onGuide)}>Guide</button><button type="button" className="secondary-button" onClick={() => act(props.onFeedback)}>Report a problem</button></div></section>}
        {(props.hasMessages || props.onStartOver) && <section className="mia-assist-section" aria-label="Conversation and setup"><h3>Conversation & setup</h3>
          {props.hasMessages && <div className="mia-assist-conversation-action"><p>Clear this conversation while keeping your saved financial information.</p><button type="button" className="secondary-button" disabled={props.busy} onClick={() => act(props.onClearChat)}>Clear chat</button></div>}
          {props.onStartOver && <div className="mia-assist-conversation-action"><p>Replace practice information with your real numbers. Review what starts fresh and what stays first.</p><button type="button" className="secondary-button" disabled={props.busy} onClick={() => act(props.onStartOver!)}>Start over with my real numbers</button></div>}
        </section>}
      </>}
    </div>
  </>
}

function ModalPanel(props: Props) {
  const ref = usePilotDialog(props.onClose)
  return createPortal(<div className="mia-assist-overlay">
    <button type="button" className="mia-assist-backdrop" aria-label="Close chat help" onClick={props.onClose} tabIndex={-1} />
    <section ref={ref} className="mia-assist-panel is-modal" role="dialog" aria-modal="true" aria-labelledby="mia-assist-title" tabIndex={-1}><PanelContent {...props} /></section>
  </div>, document.body)
}

function CompanionPanel(props: Props) {
  const ref = useRef<HTMLElement>(null)
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null
    ref.current?.querySelector<HTMLButtonElement>('header button')?.focus({ preventScroll: true })
    return () => { if (previous?.isConnected) previous.focus({ preventScroll: true }) }
  }, [])
  return <aside ref={ref} className="mia-assist-panel is-companion" aria-labelledby="mia-assist-title" onKeyDown={event => { if (event.key === 'Escape') { event.stopPropagation(); props.onClose() } }}><PanelContent {...props} /></aside>
}
