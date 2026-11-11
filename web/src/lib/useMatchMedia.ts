import { useSyncExternalStore } from 'react'

const supported = () => typeof window !== 'undefined' && typeof window.matchMedia === 'function'

/** True while the media query matches; follows the screen as it turns or resizes. */
export function useMatchMedia(query: string) {
  return useSyncExternalStore(
    callback => {
      if (!supported()) return () => {}
      const list = window.matchMedia(query)
      list.addEventListener('change', callback)
      return () => list.removeEventListener('change', callback)
    },
    () => supported() && window.matchMedia(query).matches,
    () => false,
  )
}
