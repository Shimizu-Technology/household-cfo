import { Children, isValidElement } from 'react'
import type { ReactElement, ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import { AppErrorFallback } from './AppErrorFallback'

describe('AppErrorFallback', () => {
  it('explains the safe state and wires retry to the error-boundary reset', () => {
    const resetError = vi.fn()
    const fallback = AppErrorFallback({ resetError })
    const markup = renderToStaticMarkup(fallback)
    const section = Children.only(fallback.props.children) as ReactElement<{ children: ReactNode }>
    const retry = Children.toArray(section.props.children).find((child) => (
      isValidElement<{ onClick?: () => void }>(child) && child.type === 'button'
    )) as ReactElement<{ onClick: () => void }>

    expect(markup).toContain('This screen hit an unexpected problem.')
    expect(markup).toContain('verify any changes you made just before the error')
    retry.props.onClick()
    expect(resetError).toHaveBeenCalledOnce()
  })
})
