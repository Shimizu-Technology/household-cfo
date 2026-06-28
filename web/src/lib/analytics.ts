import type { CapturedNetworkRequest } from 'posthog-js'
import type { CurrentUser, DocumentImportKind } from '../api'

type AnalyticsProps = Record<string, string | number | boolean | null | undefined>
type PostHogClient = typeof import('posthog-js').default
type PostHogConfig = NonNullable<Parameters<PostHogClient['init']>[1]>

const placeholderKeys = new Set(['YOUR_POSTHOG_KEY', 'phc_xxxxxxxxxxxxx', ''])
const posthogKey = (import.meta.env.VITE_PUBLIC_POSTHOG_KEY as string | undefined)?.trim()
const posthogHost = import.meta.env.VITE_PUBLIC_POSTHOG_HOST || 'https://us.i.posthog.com'
const enableAnalyticsInDev = import.meta.env.VITE_ENABLE_ANALYTICS_IN_DEV === 'true'

export const isAnalyticsEnabled = Boolean(posthogKey && !placeholderKeys.has(posthogKey)) &&
  (import.meta.env.PROD || enableAnalyticsInDev)
export const isSessionReplayEnabled = isAnalyticsEnabled && import.meta.env.VITE_PUBLIC_POSTHOG_SESSION_REPLAY === 'true'

let posthogPromise: Promise<PostHogClient | null> | null = null
let initialized = false
let disabledLogged = false

function compactProps(props: AnalyticsProps = {}) {
  return Object.fromEntries(Object.entries(props).filter(([, value]) => value !== undefined))
}

function redactUrl(value: string) {
  return value
    .replace(/([?&](token|auth|email|clerk|jwt|key|secret|signature|X-Amz-Signature|X-Amz-Credential)=)[^&]+/gi, '$1[REDACTED]')
    .replace(/(\/document_imports\/\d+\/source_url)([^\s]*)/gi, '$1')
}

function maskCapturedNetworkRequest(request: CapturedNetworkRequest) {
  if (request.name) request.name = redactUrl(request.name)
  return request
}

function sectionSlug(section: string) {
  return section.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'unknown'
}

function analyticsConfig(): PostHogConfig {
  return {
    api_host: posthogHost,
    defaults: '2025-11-30',
    person_profiles: 'identified_only',
    capture_pageview: false,
    capture_pageleave: true,
    autocapture: false,
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
    $current_url: window.location.href,
    $pathname: window.location.pathname,
    $hash: window.location.hash,
    section: sectionSlug(section),
    route_area: section === 'Admin' ? 'admin' : 'workspace',
    ...props,
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
}

function fileSizeBucket(size: number) {
  if (size < 250_000) return 'under_250kb'
  if (size < 1_000_000) return '250kb_1mb'
  if (size < 5_000_000) return '1mb_5mb'
  if (size < 10_000_000) return '5mb_10mb'
  return 'over_10mb'
}
