// A short, always-visible reason shown beside a disabled control. Pair it with
// aria-describedby={id} on the control so screen readers hear it as well.
export function DisabledReason({ id, children }: { id: string; children?: string | null }) {
  if (!children) return null
  return <small id={id} className="disabled-reason">{children}</small>
}
