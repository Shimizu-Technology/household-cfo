import { afterEach, expect, it, vi } from 'vitest'
import { addWorkspaceCollaborator, changeWorkspaceCollaborator, fetchWorkspaceCollaborators, removeWorkspaceCollaborator, sendWorkspaceCollaboratorEmail, setActiveCoachWorkspaceId, type WorkspaceCollaborator } from './api'

afterEach(() => { vi.unstubAllGlobals(); setActiveCoachWorkspaceId(null) })

it('binds collaborator requests to the selected program and includes the expected saved role', async () => {
  const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ member: {}, members: [], removed: true }), { status: 200, headers: { 'Content-Type': 'application/json' } })))
  vi.stubGlobal('fetch', fetchMock)
  setActiveCoachWorkspaceId(99)
  const member: WorkspaceCollaborator = { id: 7, user_id: 11, email: 'coach@example.test', full_name: 'Coach', role: 'editor', status: 'accepted', platform_admin: false, is_self: false, cohort_managed: false }
  await fetchWorkspaceCollaborators(42)
  await addWorkspaceCollaborator(42, member.email, 'viewer', false)
  await changeWorkspaceCollaborator(42, member, 'reviewer')
  await removeWorkspaceCollaborator(42, member)
  await sendWorkspaceCollaboratorEmail(42, member.id)
  expect(fetchMock.mock.calls.map(([url]) => new URL(url).pathname)).toEqual([
    '/api/v1/admin/collaborators', '/api/v1/admin/collaborators', '/api/v1/admin/collaborators/7',
    '/api/v1/admin/collaborators/7', '/api/v1/admin/collaborators/7/send_invitation',
  ])
  for (const [, request] of fetchMock.mock.calls) expect(request.headers).toMatchObject({ 'X-Coach-Workspace-Id': '42' })
  expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ collaborator: { email: member.email, role: 'viewer', send_email: false } })
  expect(JSON.parse(fetchMock.mock.calls[2][1].body)).toEqual({ collaborator: { role: 'reviewer', expected_role: 'editor' } })
  expect(JSON.parse(fetchMock.mock.calls[3][1].body)).toEqual({ collaborator: { expected_role: 'editor' } })
  expect(fetchMock.mock.calls[3][1].method).toBe('DELETE')
})
