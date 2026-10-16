// @vitest-environment jsdom
import {act,cleanup,fireEvent,render,screen} from '@testing-library/react'
import {afterEach,expect,it,vi} from 'vitest'
import {WorkspaceOpening} from './WorkspaceOpening'
afterEach(()=>{cleanup();vi.useRealTimers()})
it('keeps one message across phases and delays recovery',()=>{
 vi.useFakeTimers();const retry=vi.fn();const view=render(<WorkspaceOpening status="Checking your program…" onRetry={retry}/>);const panel=screen.getByRole('region',{name:'Opening workspace'});
 expect(screen.queryByRole('button')).toBeNull();act(()=>vi.advanceTimersByTime(4_000));view.rerender(<WorkspaceOpening status="Getting your plan ready…" onRetry={retry}/>);
 expect(screen.getByRole('region',{name:'Opening workspace'})).toBe(panel);expect(screen.getByRole('heading').textContent).toBe('Opening your workspace…');expect(screen.getByRole('status').textContent).toBe('Getting your plan ready…');expect(screen.queryByRole('button')).toBeNull();act(()=>vi.advanceTimersByTime(4_000));fireEvent.click(screen.getByRole('button',{name:'Try again'}));expect(retry).toHaveBeenCalledOnce();
})
it('stops active loading and allows immediate recovery on failure',()=>{const retry=vi.fn();render(<WorkspaceOpening status="Getting your plan ready…" error="Your workspace could not load." onRetry={retry}/>);expect(screen.getByRole('region',{name:'Opening workspace'}).getAttribute('aria-busy')).toBe('false');expect(screen.getByRole('alert').textContent).toBe('Your workspace could not load.');expect(screen.queryByRole('status')).toBeNull();fireEvent.click(screen.getByRole('button',{name:'Try again'}));expect(retry).toHaveBeenCalledOnce()})
it('names the failure in the heading instead of still saying it is opening',()=>{render(<WorkspaceOpening status="Getting your plan ready…" error="Your workspace is having trouble loading. Try again in a moment." onRetry={vi.fn()}/>);expect(screen.getByRole('heading').textContent).toBe('We couldn’t open your workspace');expect(screen.queryByText('Opening your workspace…')).toBeNull();expect(screen.getByRole('button',{name:'Try again'})).toBeTruthy()})
