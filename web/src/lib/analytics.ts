import type { CapturedNetworkRequest, CaptureResult } from 'posthog-js'
import type { CurrentUser, DocumentImportKind } from '../api'

type AnalyticsProps = Record<string, string | number | boolean | null | undefined>
export type PilotWorkflow = 'setup' | 'ask_mia' | 'voice' | 'document_upload' | 'document_review' | 'transaction_review' | 'mia_budget_review' | 'feedback'
type PostHogClient = typeof import('posthog-js').default
type PostHogConfig = NonNullable<Parameters<PostHogClient['init']>[1]>

const placeholderKeys = new Set(['YOUR_POSTHOG_KEY', 'phc_xxxxxxxxxxxxx', ''])
const posthogKey = (import.meta.env.VITE_PUBLIC_POSTHOG_KEY as string | undefined)?.trim()
const posthogUiHost = import.meta.env.VITE_PUBLIC_POSTHOG_UI_HOST || 'https://us.posthog.com'
const directPosthogHost = posthogUiHost.includes('eu.posthog.com') ? 'https://eu.i.posthog.com' : 'https://us.i.posthog.com'
const enableAnalyticsInDev = import.meta.env.VITE_ENABLE_ANALYTICS_IN_DEV === 'true'

export const isAnalyticsEnabled = Boolean(posthogKey && !placeholderKeys.has(posthogKey)) &&
  (import.meta.env.PROD || enableAnalyticsInDev)
export const isSessionReplayEnabled = isAnalyticsEnabled

function defaultPosthogHost() {
  if (!import.meta.env.PROD) return directPosthogHost
  if (typeof window !== 'undefined' && window.location.hostname.endsWith('.netlify.app')) return directPosthogHost

  return '/vera-insights'
}

let posthogPromise: Promise<PostHogClient | null> | null = null
let initialized = false
let disabledLogged = false

function compactProps(props: AnalyticsProps = {}) {
  return Object.fromEntries(Object.entries(props).filter(([, value]) => value !== undefined))
}

export function redactAnalyticsUrl(value: string) {
  const redacted = value
    .replace(/([?&](token|invitation_token|access_token|refresh_token|code|state|authorization_session_id|auth|email|clerk|jwt|key|secret|signature|X-Amz-Signature|X-Amz-Credential)=)[^&]+/gi, '$1[REDACTED]')
    .replace(/https:\/\/setup\.workos\.com\/[^\s]*/gi, 'https://setup.workos.com/[REDACTED]')
    .replace(/(\/document_imports\/\d+\/source_url)([^\s]*)/gi, '$1')
  const portalHost = String(import.meta.env.VITE_WORKOS_ADMIN_PORTAL_HOSTNAME || '').trim()
  if (!portalHost) return redacted
  try {
    const url = new URL(redacted)
    return url.hostname === portalHost ? `${url.origin}/[REDACTED]` : redacted
  } catch {
    return redacted
  }
}

export function maskCapturedNetworkRequest(request: CapturedNetworkRequest) {
  // Remote recording settings must never enable capture of session tokens,
  // financial payloads, uploaded documents or Authorization/Cookie headers.
  delete request.requestHeaders
  delete request.responseHeaders
  delete request.requestBody
  delete request.responseBody
  try {
    if (new URL(request.name, 'https://app.invalid').pathname.startsWith('/api/auth/')) return null
  } catch { /* URL redaction below still applies to nonstandard request names. */ }
  if (request.name) request.name = redactAnalyticsUrl(request.name)
  return request
}

export function redactAnalyticsEvent(event: CaptureResult | null) {
  if (!event) return null
  const scrubUrls = (properties: Record<string, unknown> | undefined) => {
    if (!properties) return
    for (const key of ['$current_url', '$referrer', '$initial_current_url', '$initial_referrer']) {
      if (typeof properties[key] === 'string') properties[key] = redactAnalyticsUrl(properties[key])
    }
  }
  scrubUrls(event.properties)
  scrubUrls(event.$set)
  scrubUrls(event.$set_once)
  scrubUrls(event.properties.$set)
  scrubUrls(event.properties.$set_once)
  return event
}

function sectionSlug(section: string) {
  return section.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'unknown'
}

function analyticsConfig(): PostHogConfig {
  return {
    api_host: defaultPosthogHost(),
    ui_host: posthogUiHost,
    defaults: '2025-11-30',
    person_profiles: 'identified_only',
    capture_pageview: false,
    capture_pageleave: true,
    autocapture: false,
    before_send: redactAnalyticsEvent,
    disable_session_recording: !isSessionReplayEnabled,
    session_recording: isSessionReplayEnabled
      ? {
          maskAllInputs: true,
          maskTextSelector: '*',
          maskCapturedNetworkRequestFn: maskCapturedNetworkRequest,
        }
      : undefined,
  }
}

async function getPostHog() {
  if (!isAnalyticsEnabled || !posthogKey || typeof window === 'undefined') return null

  posthogPromise ||= import('posthog-js')
    .then(({ default: posthog }) => {
      if (!initialized) {
        posthog.init(posthogKey, analyticsConfig())
        initialized = true
      }

      return posthog
    })
    .catch((error) => {
      if (import.meta.env.DEV) console.warn('PostHog initialization failed', error)
      return null
    })

  return posthogPromise
}

export function initializeAnalytics() {
  if (!isAnalyticsEnabled) {
    if (import.meta.env.DEV && !disabledLogged) {
      console.info('PostHog not configured - analytics disabled')
      disabledLogged = true
    }
    return
  }

  void getPostHog()
}

export function captureAnalyticsEvent(event: string, props: AnalyticsProps = {}) {
  if (!isAnalyticsEnabled) return

  void getPostHog().then((posthog) => {
    posthog?.capture(event, compactProps(props))
  })
}

export function captureSectionPageview(section: string, props: AnalyticsProps = {}) {
  if (!isAnalyticsEnabled || typeof window === 'undefined') return

  captureAnalyticsEvent('$pageview', {
    ...props,
    $current_url: `${window.location.origin}${window.location.pathname}`,
    $pathname: window.location.pathname,
    section: sectionSlug(section),
    route_area: section === 'Admin' ? 'admin' : 'workspace',
  })
}

export function identifyAnalyticsUser(user: CurrentUser) {
  if (!isAnalyticsEnabled) return

  void getPostHog().then((posthog) => {
    posthog?.identify(`household-cfo:${user.id}`, compactProps({
      app_role: user.role,
      invitation_status: user.invitation_status,
      is_admin: user.is_admin,
      is_staff: user.is_staff,
    }))
  })
}

export function resetAnalytics() {
  if (!isAnalyticsEnabled) return

  void getPostHog().then((posthog) => {
    posthog?.reset()
  })
}

export function trackDocumentUpload(kind: DocumentImportKind, status: 'started' | 'succeeded' | 'failed', file?: File | null) {
  captureAnalyticsEvent(`document_import_upload_${status}`, {
    document_kind: kind,
    file_extension: file?.name.split('.').pop()?.toLowerCase() || null,
    size_bucket: file ? fileSizeBucket(file.size) : null,
  })
  if (status === 'failed') trackPilotWorkflowFailure('document_upload', 'upload', { document_kind: kind })
}

export function trackPilotWorkflowFailure(workflow: PilotWorkflow, stage: string, props: AnalyticsProps = {}) {
  captureAnalyticsEvent('pilot_workflow_failed', {
    ...props,
    workflow,
    stage: sectionSlug(stage),
  })
}

function fileSizeBucket(size: number) {
  if (size < 250_000) return 'under_250kb'
  if (size < 1_000_000) return '250kb_1mb'
  if (size < 5_000_000) return '1mb_5mb'
  if (size < 10_000_000) return '5mb_10mb'
  return 'over_10mb'
}
