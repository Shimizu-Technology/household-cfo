import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { browserBrandHostname, fetchPublicBrand, type BrandConfig, type BrandRuntime } from '../api'
import { BrandContext, NEUTRAL_BRAND, type BrandBootstrapStatus, useBrand } from './brandContextValue'

const fulfilledBrandCache = new Map<string, Awaited<ReturnType<typeof fetchPublicBrand>>>()
const BOOTSTRAP_TIMEOUT_MS = 9_000

export function BrandProvider({ children }: { children: ReactNode }) {
  const hostname = browserBrandHostname()
  const cached = fulfilledBrandCache.get(hostname)
  const [attempt, setAttempt] = useState(0)
  const [brand, setBrand] = useState<BrandConfig>(cached?.brand ?? NEUTRAL_BRAND)
  const [source, setSource] = useState(cached?.source ?? 'safe_default')
  const [status, setStatus] = useState<BrandBootstrapStatus>(cached?.available ? 'ready' : 'loading')
  const [error, setError] = useState<string | null>(null)
  const generationRef = useRef(0)

  useEffect(() => {
    let active = true
    const cachedResult = fulfilledBrandCache.get(hostname)
    if (cachedResult?.available) return

    const generation = generationRef.current + 1
    generationRef.current = generation
    const controller = new AbortController()
    let timeoutReached = false
    const timeout = window.setTimeout(() => {
      timeoutReached = true
      controller.abort(new DOMException('Branding request timed out', 'TimeoutError'))
    }, BOOTSTRAP_TIMEOUT_MS)
    void fetchPublicBrand(hostname, controller.signal)
      .then((result) => {
        if (!active || controller.signal.aborted || generationRef.current !== generation) return
        if (result.available) fulfilledBrandCache.set(hostname, result)
        setBrand(result.available ? result.brand : NEUTRAL_BRAND)
        setSource(result.source)
        setStatus(result.available ? 'ready' : 'unavailable')
      })
      .catch((requestError: unknown) => {
        if (!active || generationRef.current !== generation) return
        setBrand(NEUTRAL_BRAND)
        setSource('safe_default')
        setStatus('error')
        const timedOut = timeoutReached || (requestError instanceof Error && ['AbortError', 'TimeoutError'].includes(requestError.name))
        setError(timedOut
          ? 'This program took too long to load. Check your connection and try again.'
          : 'Your program could not load. Check your connection and try again. If the problem continues, contact your coach.')
      })
      .finally(() => window.clearTimeout(timeout))

    return () => {
      active = false
      window.clearTimeout(timeout)
      controller.abort()
    }
  }, [attempt, hostname])

  const retry = useCallback(() => {
    fulfilledBrandCache.delete(hostname)
    setBrand(NEUTRAL_BRAND)
    setSource('safe_default')
    setStatus('loading')
    setError(null)
    setAttempt((value) => value + 1)
  }, [hostname])

  const value = useMemo(() => ({
    brand,
    assistantName: 'your assistant',
    hostname,
    source,
    status,
    error,
    retry,
    isRuntimeBrand: false,
  }), [brand, error, hostname, retry, source, status])

  return <BrandContext.Provider value={value}>{children}</BrandContext.Provider>
}

export function BrandRuntimeProvider({ runtime, assistantName, children }: {
  runtime: BrandRuntime
  assistantName: string
  children: ReactNode
}) {
  const parent = useBrand()
  const value = useMemo(() => ({
    ...parent,
    brand: runtime.available ? runtime.config : NEUTRAL_BRAND,
    assistantName: assistantName.trim() || 'your assistant',
    source: runtime.source,
    status: runtime.available ? 'ready' as const : 'unavailable' as const,
    isRuntimeBrand: true,
  }), [assistantName, parent, runtime])

  return <BrandContext.Provider value={value}>{children}</BrandContext.Provider>
}
