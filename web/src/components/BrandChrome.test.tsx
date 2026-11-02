// @vitest-environment jsdom
import { cleanup, fireEvent, render } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { NEUTRAL_BRAND } from '../contexts/brandContextValue'
import { BrandLogo } from './BrandChrome'

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
