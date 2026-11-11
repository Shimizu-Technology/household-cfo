// @vitest-environment jsdom
import { act, cleanup, render, renderHook, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { useCoachWorkspaceMutationLifecycle, useHoldWorkspaceLock, useWorkspaceMutationInFlight } from './coachWorkspaceMutationLifecycle'

afterEach(cleanup)

describe('the program picker lock', () => {
  it('is held while any save has begun and not finished, across screens', () => {
    const picker = renderHook(() => useWorkspaceMutationInFlight())
    const first = renderHook(() => useCoachWorkspaceMutationLifecycle(5))
    const second = renderHook(() => useCoachWorkspaceMutationLifecycle(5))
    expect(picker.result.current).toBe(false)
    let one!: ReturnType<typeof first.result.current.begin>
    let two!: ReturnType<typeof second.result.current.begin>
    act(() => { one = first.result.current.begin() })
    expect(picker.result.current).toBe(true)
    act(() => { two = second.result.current.begin() })
    act(() => first.result.current.finish(one))
    expect(picker.result.current).toBe(true)
    act(() => second.result.current.finish(two))
    expect(picker.result.current).toBe(false)
  })

  it('does not count the same save finishing twice', () => {
    const picker = renderHook(() => useWorkspaceMutationInFlight())
    const lifecycle = renderHook(() => useCoachWorkspaceMutationLifecycle(5))
    const other = renderHook(() => useCoachWorkspaceMutationLifecycle(5))
    let held!: ReturnType<typeof other.result.current.begin>
    let ticket!: ReturnType<typeof lifecycle.result.current.begin>
    act(() => { held = other.result.current.begin(); ticket = lifecycle.result.current.begin() })
    act(() => { lifecycle.result.current.finish(ticket); lifecycle.result.current.finish(ticket) })
    expect(picker.result.current).toBe(true)
    act(() => other.result.current.finish(held))
    expect(picker.result.current).toBe(false)
  })

  it('is held by a form that is saving, and let go when it finishes or goes away', () => {
    function Form({ busy }: { busy: boolean }) { useHoldWorkspaceLock(busy); return null }
    function Picker() { return <p>{useWorkspaceMutationInFlight() ? 'locked' : 'free'}</p> }
    const view = render(<><Picker /><Form busy={false} /></>)
    expect(screen.getByText('free')).toBeTruthy()
    view.rerender(<><Picker /><Form busy /></>)
    expect(screen.getByText('locked')).toBeTruthy()
    view.rerender(<><Picker /></>)
    expect(screen.getByText('free')).toBeTruthy()
  })
})
