// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ChatMoreMenu } from './ChatMoreMenu'
import { MiaDisclaimer } from './MiaDisclaimer'
import { brandByline, brandHeaderByline } from '../lib/brandByline'
import { NEUTRAL_BRAND } from '../contexts/brandContextValue'

afterEach(() => cleanup())

const fullText = 'Mia is an AI coaching assistant built from Mrs. Mel’s approved guidance. Mia does not impersonate or replace that coach and does not replace legal, tax, investment, accounting, therapeutic, or financial advice.'

describe('MiaDisclaimer', () => {
  it('shows one short line and keeps the full disclosure one tap away', async () => {
    render(<MiaDisclaimer assistantName="Mia" fullText={fullText} />)

    expect(screen.getByText(/Mia is an AI coaching assistant, not a legal, tax or financial advisor\./)).toBeTruthy()
    const about = screen.getByRole('button', { name: 'About Mia' })
    expect(about.getAttribute('aria-expanded')).toBe('false')
    expect(screen.getByText(fullText).hidden).toBe(true)

    await userEvent.click(about)
    expect(about.getAttribute('aria-expanded')).toBe('true')
    expect(screen.getByText(fullText).hidden).toBe(false)

    await userEvent.click(about)
    expect(screen.getByText(fullText).hidden).toBe(true)
  })

  it('keeps the short line when there is no fuller text', () => {
    render(<MiaDisclaimer assistantName="Mia" fullText={null} />)
    expect(screen.getByText(/not a legal, tax or financial advisor/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: /About/ })).toBeNull()
  })
})

describe('ChatMoreMenu', () => {
  it('opens secondary chat actions and returns focus to More after a choice', async () => {
    const onPrompts = vi.fn()
    const onClear = vi.fn()
    render(<ChatMoreMenu note="Plan context: October 2026" items={[
      { key: 'prompts', label: 'Prompts', onSelect: onPrompts },
      { key: 'clear', label: 'Clear chat', onSelect: onClear, disabled: true },
    ]} />)

    const more = screen.getByRole('button', { name: 'More chat options' })
    expect(more.getAttribute('aria-expanded')).toBe('false')
    expect(screen.queryByRole('button', { name: 'Prompts' })).toBeNull()

    await userEvent.click(more)
    expect(more.getAttribute('aria-expanded')).toBe('true')
    expect(screen.getByText('Plan context: October 2026')).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Clear chat' }) as HTMLButtonElement).disabled).toBe(true)
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Prompts' }))

    await userEvent.click(screen.getByRole('button', { name: 'Prompts' }))
    expect(onPrompts).toHaveBeenCalledWith(more)
    expect(onClear).not.toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Prompts' })).toBeNull()
    expect(document.activeElement).toBe(more)
  })

  it('closes on Escape and on an outside press', async () => {
    render(<><button type="button">Outside</button><ChatMoreMenu items={[{ key: 'prompts', label: 'Prompts', onSelect: vi.fn() }]} /></>)
    const more = screen.getByRole('button', { name: 'More chat options' })

    await userEvent.click(more)
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('button', { name: 'Prompts' })).toBeNull()
    expect(document.activeElement).toBe(more)

    await userEvent.click(more)
    await userEvent.click(screen.getByRole('button', { name: 'Outside' }))
    expect(screen.queryByRole('button', { name: 'Prompts' })).toBeNull()
  })
})

describe('brand bylines', () => {
  const legacy = { ...NEUTRAL_BRAND, product_name: 'Household CFO', short_name: 'Household CFO', organization_name: 'Household CFO Method', powered_by_name: 'VERA', powered_by_placement: 'header' as const }

  it('never names the platform to participants', () => {
    expect(brandByline(legacy)).toBe('Household CFO Method')
    expect(brandByline({ ...legacy, powered_by_placement: 'footer' })).not.toMatch(/VERA/)
  })

  it('only repeats the organization in the header when it adds something', () => {
    expect(brandHeaderByline(legacy)).toBeNull()
    expect(brandHeaderByline({ ...legacy, organization_name: 'ASC Trust' })).toBe('ASC Trust')
  })

  it('uses the consumer brand for the neutral fallback', () => {
    expect(NEUTRAL_BRAND.product_name).toBe('Household CFO')
    expect(JSON.stringify(NEUTRAL_BRAND)).not.toMatch(/VERA/)
  })
})
