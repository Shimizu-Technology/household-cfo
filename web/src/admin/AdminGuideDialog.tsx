import { usePilotDialog } from '../lib/usePilotDialog'

export function AdminGuideDialog({ onClose }: { onClose: () => void }) {
  const { dialogRef, requestClose } = usePilotDialog(onClose)
  return <div className="pilot-dialog-overlay" data-dialog-surface="true" role="presentation">
    <button type="button" className="pilot-dialog-backdrop" aria-label="Close guide" onClick={requestClose} />
    <section ref={dialogRef} data-dialog-panel="true" className="pilot-dialog pilot-guide-dialog" role="dialog" aria-modal="true" aria-labelledby="admin-guide-title" tabIndex={-1}>
      <header><div><h2 id="admin-guide-title">Your coaching workspace.</h2></div><button type="button" className="secondary-button" onClick={requestClose}>Close</button></header>
      <div className="pilot-dialog-body">
        <ol className="pilot-guide-steps">
          <li><span>1</span><div><strong>Start with Today.</strong><p>Choose a group and see who needs help. Open a person only for what they have chosen to share.</p></div></li>
          <li><span>2</span><div><strong>Set up your assistant, then go live.</strong><p>Coaching holds the voice, teaching and tools. Review every change before it reaches your people.</p></div></li>
          <li><span>3</span><div><strong>Try it as a client would.</strong><p>Go to My household, then choose a group under Use the app as. You see what they see, and you are never counted in the group.</p></div></li>
        </ol>
      </div>
    </section>
  </div>
}
