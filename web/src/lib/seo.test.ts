// @vitest-environment jsdom

import { describe, expect, it } from 'vitest'
import { canonicalUrl, getSiteUrl, socialImageUrl, webApplicationStructuredData } from './seo'

describe('runtime coach-domain metadata', () => {
  it('uses the current browser origin instead of the generic build-time deployment URL', () => {
    expect(getSiteUrl()).toBe(window.location.origin)
    expect(canonicalUrl()).toBe(`${window.location.origin}/`)
    expect(socialImageUrl()).toBe(`${window.location.origin}/og-image.png`)
    expect(webApplicationStructuredData().url).toBe(`${window.location.origin}/`)
  })
})
