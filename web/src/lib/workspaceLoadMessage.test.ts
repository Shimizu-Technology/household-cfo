import { expect, it } from 'vitest'
import { ApiRequestError } from '../api'
import { workspaceLoadMessage } from './workspaceLoadMessage'

it('never shows authentication plumbing or server faults to participants', () => {
  expect(workspaceLoadMessage(new ApiRequestError('Missing bearer token', { status: 401 }))).toBe('Your sign-in has ended. Sign in again to open your workspace.')
  expect(workspaceLoadMessage(new ApiRequestError('PG::ConnectionBad', { status: 503 }))).toBe('Your workspace is having trouble loading. Try again in a moment.')
})

it('keeps participant-facing API messages and falls back for network failures', () => {
  expect(workspaceLoadMessage(new ApiRequestError('Choose a program to continue.', { status: 409 }))).toBe('Choose a program to continue.')
  expect(workspaceLoadMessage(new TypeError('Failed to fetch'))).toBe('Your workspace is offline for a moment. Check your connection and try again.')
})
