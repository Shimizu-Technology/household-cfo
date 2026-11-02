import { afterEach, expect, it, vi } from 'vitest'
import { fetchPublicBrand, setActiveCoachWorkspaceId, setApiActorIdentity, setAuthTokenGetter, uploadWorkspaceBrandLogo } from './api'
import { NEUTRAL_BRAND } from './contexts/brandContextValue'

afterEach(() => {
  setApiActorIdentity(null)
  setActiveCoachWorkspaceId(null)
  setAuthTokenGetter(null)
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

it('uploads multipart content to the authenticated current workspace with its exact revision', async () => {
  setApiActorIdentity('coach-a')
  setActiveCoachWorkspaceId(23)
  setAuthTokenGetter(async () => 'fictional-token')
  const configuration = { draft_revision: 8, draft: NEUTRAL_BRAND }
  const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(new Response(JSON.stringify({ brand_configuration: configuration })))
  vi.stubGlobal('fetch', fetch)
  const file = new File(['png'], 'program.png', { type: 'image/png' })
  expect(await uploadWorkspaceBrandLogo(file, 7)).toEqual(configuration)
  expect(fetch.mock.calls[0][0]).toContain('/api/v1/admin/brand/logo')
  const options = fetch.mock.calls[0][1]!
  const headers = new Headers(options.headers)
  expect(headers.get('Authorization')).toBe('Bearer fictional-token')
  expect(headers.get('X-Coach-Workspace-Id')).toBe('23')
  expect(headers.has('Content-Type')).toBe(false) // fetch supplies the multipart boundary.
  expect(options.method).toBe('POST')
  expect((options.body as FormData).get('draft_revision')).toBe('7')
  expect((options.body as FormData).get('file')).toBe(file)
})

it('rejects an upload response after the program changes', async () => {
  setActiveCoachWorkspaceId(23)
  let finish!: (response: Response) => void
  const fetch = vi.fn<typeof globalThis.fetch>().mockImplementation(() => new Promise(resolve => { finish = resolve }))
  vi.stubGlobal('fetch', fetch)
  const pending = uploadWorkspaceBrandLogo(new File(['png'], 'program.png', { type: 'image/png' }), 7)
  const rejected = expect(pending).rejects.toThrow('Your account or program changed')
  await vi.waitFor(() => expect(fetch).toHaveBeenCalledOnce())
  setActiveCoachWorkspaceId(24)
  finish(new Response(JSON.stringify({ brand_configuration: { draft_revision: 8 } })))
  await rejected
})

it('allows only the generated localhost HTTP logo route while keeping other asset URLs HTTPS', async () => {
  const fetch = vi.fn<typeof globalThis.fetch>()
  vi.stubGlobal('fetch', fetch)
  for (const logo of ['http://127.0.0.1:3204/api/public/brand_logos/signed-token', 'http://127.0.0.1:3204/other.png', 'http://external.test/api/public/brand_logos/signed-token']) {
    fetch.mockResolvedValueOnce(new Response(JSON.stringify({ brand: { ...NEUTRAL_BRAND, logo_url: logo }, available: true, source: 'test' })))
    const request = fetchPublicBrand('localhost')
    if (logo.includes('/127.0.0.1:3204/api/')) expect((await request).brand.logo_url).toBe(logo)
    else await expect(request).rejects.toThrow('invalid brand configuration')
  }
})
