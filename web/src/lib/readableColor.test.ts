import { describe, expect, it } from 'vitest'
import { readableOn } from './readableColor'

describe('readableOn', () => {
  it('darkens the default muted text until it reads on the soft rose surface', () => {
    const muted = readableOn('#706d66', ['#fffdf8', '#fbf7ef', '#f7f2ea', '#f1e2e3'])
    expect(muted).not.toBe('#706d66')
    // #66625b-ish: at least 4.5:1 on #f1e2e3
    const [r, g, b] = [1, 3, 5].map((index) => parseInt(muted.slice(index, index + 2), 16))
    expect(r).toBeLessThan(0x70)
    expect(g).toBeLessThan(0x6d)
    expect(b).toBeLessThan(0x66)
  })

  it('lightens text when no darker shade can read on a mid-tone surface', () => {
    // Black reaches only 3.66:1 on #666666, so darkening cannot work here.
    const lightened = readableOn('#aaaaaa', ['#000000', '#666666'])
    expect(lightened).not.toBe('#aaaaaa')
    const [r, g, b] = [1, 3, 5].map((index) => parseInt(lightened.slice(index, index + 2), 16))
    expect(Math.min(r, g, b)).toBeGreaterThan(0xaa)
  })

  it('keeps the colour when neither direction can reach the minimum', () => {
    expect(readableOn('#888888', ['#000000', '#ffffff'])).toBe('#888888')
  })

  it('leaves colours that already read, and values it cannot parse, alone', () => {
    expect(readableOn('#4a4640', ['#fffdf8', '#f1e2e3'])).toBe('#4a4640')
    expect(readableOn('rgb(1, 2, 3)', ['#ffffff'])).toBe('rgb(1, 2, 3)')
    expect(readableOn('#706d66', ['not-a-color'])).toBe('#706d66')
  })
})
