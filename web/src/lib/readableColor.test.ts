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

  it('leaves colours that already read, and values it cannot parse, alone', () => {
    expect(readableOn('#4a4640', ['#fffdf8', '#f1e2e3'])).toBe('#4a4640')
    expect(readableOn('rgb(1, 2, 3)', ['#ffffff'])).toBe('rgb(1, 2, 3)')
    expect(readableOn('#706d66', ['not-a-color'])).toBe('#706d66')
  })
})
