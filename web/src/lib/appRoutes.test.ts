// @vitest-environment jsdom
import { beforeEach, expect, it } from 'vitest'
import { adminPath, adminSectionsOf, legacyStaffRedirect, navigateTo, parseAdminRoute, rememberMode, restoredMode } from './appRoutes'
import { previewGroupsOf, setPreviewGroups } from './previewGroups'
import type { CurrentUser } from '../api'

beforeEach(() => { window.localStorage.clear(); window.history.replaceState({}, '', '/') })

it('reads /admin and /admin/<section> as the Admin side and everything else as the app', () => {
  expect(parseAdminRoute('/admin')).toEqual({ section: null })
  expect(parseAdminRoute('/admin/')).toEqual({ section: null })
  expect(parseAdminRoute('/admin/people')).toEqual({ section: 'people' })
  expect(parseAdminRoute('/')).toBeNull()
  expect(parseAdminRoute('/administrator')).toBeNull()
  expect(parseAdminRoute('/admin/people/extra')).toBeNull()
  expect(adminPath('groups')).toBe('/admin/groups')
})

it('moves old #Coach Studio and #Admin links to their sections and keeps the query', () => {
  expect(legacyStaffRedirect({ hash: '#Coach%20Studio', search: '' })).toBe('/admin/today')
  expect(legacyStaffRedirect({ hash: '#Coach%20Studio', search: '?coach_area=live&coach_task=voice' })).toBe('/admin/coaching?coach_area=live&coach_task=voice')
  expect(legacyStaffRedirect({ hash: '#Coach%20Studio', search: '?coach_area=people' })).toBe('/admin/today?coach_area=people')
  expect(legacyStaffRedirect({ hash: '#Admin', search: '?x=1' })).toBe('/admin/people?x=1')
  expect(legacyStaffRedirect({ hash: '#Budget', search: '' })).toBeNull()
  expect(legacyStaffRedirect({ hash: '#%E0%A4%A', search: '' })).toBeNull()
})

it('remembers where a person last was and falls back to the app', () => {
  const user = { id: 9 }
  expect(restoredMode(user)).toEqual({ mode: 'app' })
  rememberMode(user, { mode: 'admin', section: 'groups' })
  expect(restoredMode(user)).toEqual({ mode: 'admin', section: 'groups' })
  expect(restoredMode({ id: 10 })).toEqual({ mode: 'app' })
  rememberMode(user, { mode: 'app' })
  expect(restoredMode(user)).toEqual({ mode: 'app' })
  window.localStorage.setItem('household-cfo:mode:v1:9', '{not json')
  expect(restoredMode(user)).toEqual({ mode: 'app' })
})

it('moves through history without a page load and tells the app', () => {
  let heard = 0
  const listener = () => { heard += 1 }
  window.addEventListener('household-cfo:navigate', listener)
  navigateTo('/admin/support')
  expect(window.location.pathname).toBe('/admin/support')
  navigateTo('/', { replace: true })
  expect(window.location.pathname).toBe('/')
  expect(heard).toBe(2)
  window.removeEventListener('household-cfo:navigate', listener)
})

it('treats a missing or malformed section list as no Admin side', () => {
  expect(adminSectionsOf(null)).toEqual([])
  expect(adminSectionsOf({ admin_sections: undefined } as CurrentUser)).toEqual([])
  expect(adminSectionsOf({ admin_sections: 'all' } as unknown as CurrentUser)).toEqual([])
})

it('prefers the freshest group list for the same person and ignores another person’s', () => {
  const user = { id: 5, preview_groups: [{ cohort_id: 1, name: 'A', status: 'active', program_name: 'P', seated: false, challenge: false, challenge_joined: false }] } as unknown as CurrentUser
  expect(previewGroupsOf(user)[0].seated).toBe(false)
  setPreviewGroups(5, [{ ...previewGroupsOf(user)[0], seated: true }])
  expect(previewGroupsOf(user)[0].seated).toBe(true)
  expect(previewGroupsOf({ ...user, id: 6 } as CurrentUser)[0].seated).toBe(false)
  expect(previewGroupsOf(null)).toEqual([])
})
