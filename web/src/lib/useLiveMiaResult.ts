import { useEffect, useState } from 'react'

/** Only the transition observed by this mounted card fades; restored history is still. */
export function useLiveMiaResult(complete: boolean, ready = true) {
  const [result, setResult] = useState<{ complete: boolean | null; live: boolean }>({ complete: ready ? complete : null, live: false })
  if (ready && complete !== result.complete) setResult({ complete, live: result.complete !== null && complete })
  useEffect(() => {
    if (!result.live) return
    const timer = window.setTimeout(() => setResult(current => ({ ...current, live: false })), 180)
    return () => window.clearTimeout(timer)
  }, [result.live])
  return result.live ? ' is-live-result' : ''
}
