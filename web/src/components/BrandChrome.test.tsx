// @vitest-environment jsdom
import { cleanup, fireEvent, render } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { NEUTRAL_BRAND } from '../contexts/brandContextValue'
import { BrandRuntimeProvider } from '../contexts/BrandContext'
import { BrandFooter, BrandLogo, BrandWordmark } from './BrandChrome'

afterEach(cleanup)

describe('participant program logo', () => {
  it('shows the configured logo beside the existing program name without leaking a referrer', () => {
    const brand = { ...NEUTRAL_BRAND, logo_url: 'https://api.example.test/api/public/brand_logos/signed-logo' }
    const { container } = render(<BrandLogo brand={brand} />)
    const image = container.querySelector('img')!
    expect(image.src).toBe(brand.logo_url)
    expect(image.alt).toBe('')
    expect(image.getAttribute('referrerpolicy')).toBe('no-referrer')
  })

  it('hides a broken logo and recovers when a different logo is configured', () => {
    const brand = { ...NEUTRAL_BRAND, logo_url: 'https://api.example.test/logo.png' }
    const view = render(<BrandLogo brand={brand} />)
    fireEvent.error(view.container.querySelector('img')!)
    expect(view.container.querySelector('img')).toBeNull()
    view.rerender(<BrandLogo brand={{ ...brand, logo_url: 'https://api.example.test/replacement.png' }} />)
    expect(view.container.querySelector('img')?.src).toBe('https://api.example.test/replacement.png')
  })
})

describe('closing line', () => {
  const method = { ...NEUTRAL_BRAND, organization_name: 'Household CFO Method', footer: { text: 'Educational guidance only.', privacy_url: null, terms_url: null } }
  const inBrand = (brand: typeof method, closingLine?: boolean) => render(
    <BrandRuntimeProvider runtime={{ available: true, source: 'workspace', config: brand } as never} assistantName="Mia">
      <BrandFooter closingLine={closingLine} />
    </BrandRuntimeProvider>,
  )

  it('shows her line above the disclaimer on her own method brand when the screen asks for it', () => {
    const { container } = inBrand(method, true)
    const line = container.querySelector('.brand-closing-line')!
    expect(line.textContent).toContain('Not just to look wealthy on paper. The goal is to feel safe in your actual life.')
    expect(line.textContent).toContain('The Household CFO Method')
    expect(container.querySelector('.brand-footer p:not(.brand-closing-line)')?.textContent).toBe('Educational guidance only.')
    expect(line.compareDocumentPosition(container.querySelector('.brand-footer p:not(.brand-closing-line)')!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('is off unless the screen opts in, so the savings program can keep its own name', () => {
    expect(inBrand(method).container.querySelector('.brand-closing-line')).toBeNull()
    expect(inBrand(method, false).container.querySelector('.brand-closing-line')).toBeNull()
  })

  it('is never inherited by a coach workspace with its own organization name', () => {
    const { container } = inBrand({ ...method, organization_name: 'Island Money Coaching' }, true)
    expect(container.querySelector('.brand-closing-line')).toBeNull()
    expect(container.textContent).toContain('Educational guidance only.')
  })
})


describe('shell wordmark', () => {
  it('uses the italic only for Household CFO Method', () => {
    const view = render(<BrandWordmark brand={{ ...NEUTRAL_BRAND, organization_name: 'Household CFO Method' }} />)
    expect(view.container.textContent).toBe('The Household CFO')
    expect(view.container.querySelector('em')?.textContent).toBe('Household CFO')
    view.rerender(<BrandWordmark brand={{ ...NEUTRAL_BRAND, organization_name: 'Island Coaching', short_name: 'Island Money' }} />)
    expect(view.container.textContent).toBe('Island Money')
    expect(view.container.querySelector('em')).toBeNull()
  })
})
