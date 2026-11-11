import { useEffect, useRef, type ReactNode } from 'react'
import { Button } from './Button'

type BibaCardProps = {
  title: string
  children: ReactNode
  actionLabel: string
  onAction: () => void
}

/**
 * "Biba!": one card for a finished milestone. A serif headline, one plain sentence with the
 * participant's real figure, and one action. It takes focus so a keyboard or screen-reader user
 * lands on it and the page scrolls to it; the fade is CSS (styles/cards.css) and respects reduced motion.
 */
export function BibaCard({ title, children, actionLabel, onAction }: BibaCardProps) {
  const card = useRef<HTMLElement>(null)
  useEffect(() => {
    card.current?.focus({ preventScroll: true })
    card.current?.scrollIntoView?.({ block: 'nearest' })
  }, [])
  return <section ref={card} className="biba-card" tabIndex={-1} aria-labelledby="biba-card-title">
    <h3 id="biba-card-title">{title}</h3>
    <p>{children}</p>
    <Button onClick={onAction}>{actionLabel}</Button>
  </section>
}
