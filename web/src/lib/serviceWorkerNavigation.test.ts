import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { expect, it, vi } from 'vitest'

it.each(['text/plain', 'application/pdf', 'text/html'])('only HTML navigation can replace the offline shell: %s', async contentType => {
  const listeners: Record<string, (event: unknown) => void> = {}
  const put = vi.fn()
  const response = { ok: true, headers: new Headers({ 'Content-Type': contentType }), clone: () => response }
  runInNewContext(readFileSync(new URL('../../public/sw.js', import.meta.url), 'utf8'), {
    self: { location: { origin: 'https://example.test' }, addEventListener: (name: string, handler: (event: unknown) => void) => { listeners[name] = handler } },
    URL, fetch: async () => response, caches: { open: async () => ({ put }) },
  })
  let pending: Promise<unknown> | undefined
  listeners.fetch({ request: { method: 'GET', mode: 'navigate', url: 'https://example.test/third-party/libheif-COPYING.txt' }, respondWith: (promise: Promise<unknown>) => { pending = promise } })
  await pending
  await Promise.resolve()
  expect(put).toHaveBeenCalledTimes(contentType === 'text/html' ? 1 : 0)
})
