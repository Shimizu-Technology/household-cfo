import { useEffect, useId, useRef, useState, type FormEvent } from 'react'
import { createPortal } from 'react-dom'
import { ApiRequestError } from '../api'
import { useBrand } from '../contexts/brandContextValue'
import type { AuthSignInOptions } from '../contexts/authContextValue'
import { usePilotDialog } from '../lib/usePilotDialog'
import { useDialogViewport } from '../lib/useDialogViewport'
import './WorkosSignInDialog.css'

export type DialogEmailAuthStep =
  | { step: 'code'; challenge_id: string; email: string; expires_at: string; resend_after: number }
  | { step: 'complete'; return_to: string }
  | { step: 'redirect'; authorization_url: string }

export type WorkosSignInClient = {
  authOptions: () => Promise<{ google_enabled: boolean }>
  startEmail: (options: AuthSignInOptions & { email: string }) => Promise<DialogEmailAuthStep>
  verifyEmail: (challengeId: string, code: string) => Promise<DialogEmailAuthStep>
  resendEmail: (challengeId: string) => Promise<DialogEmailAuthStep>
  cancelEmail: (challengeId: string) => Promise<void>
}

type Props = {
  client: WorkosSignInClient; options?: AuthSignInOptions; screen: 'sign-in' | 'sign-up'
  onClose: () => void; onAuthenticated: (returnTo: string) => void | Promise<void>
  onExternalSignIn: (method: 'google' | 'sso', authorizationUrl?: string) => Promise<void>
  externalError?: string | null
  onCancelExternal?: () => void
}

const errorCopy: Record<string, string> = {
  invalid_code: 'That code did not match. Check the latest email and try again.',
  email_code_invalid: 'That code did not match. Check the latest email and try again.',
  expired_code: 'That code has expired. Request a new code to continue.',
  challenge_expired: 'This sign-in attempt has expired. Start again with your email.',
  email_challenge_expired: 'This sign-in attempt has expired. Start again with your email.',
  auth_rate_limited: 'Please wait a moment before trying again.',
  invitation_invalid: 'This invitation is no longer valid. Ask your program team for a new invitation.',
  invitation_required: 'Use the email your program invited, or ask your program team for access.',
  program_access_denied: 'Use the email your program invited, or ask your program team for access.',
  account_changed: 'Your account changed in another tab. Close this dialog and check your current account.',
  cancelled: 'Sign-in was canceled. You can try again when you’re ready.',
  sso_required: 'Your organization requires secure work sign-in. Continue with your invited email to use its sign-in flow.',
}

const CODE_SENT = 'We sent a six-digit code to your email.'

// Google's standard four-color "G", inline so it never pops in after the dialog opens.
function GoogleMark() {
  return <svg className="workos-google-mark" width="20" height="20" viewBox="0 0 48 48" aria-hidden="true" focusable="false">
    <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
    <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
    <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
    <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
  </svg>
}

function safeError(error: unknown) {
  if (error instanceof ApiRequestError && error.code === 'auth_rate_limited') {
    const seconds = error.payload.retry_after_sec
    if (typeof seconds === 'number' && Number.isInteger(seconds) && seconds > 0 && seconds <= 3600) {
      const minutes = Math.ceil(seconds / 60)
      return `Too many sign-in attempts. Try again in about ${minutes} ${minutes === 1 ? 'minute' : 'minutes'}.`
    }
  }
  if (error instanceof ApiRequestError && error.code && Object.hasOwn(errorCopy, error.code)) return errorCopy[error.code]
  return 'Sign-in is temporarily unavailable. Please try again.'
}

export function WorkosSignInDialog({ client, options = {}, screen, onClose, onAuthenticated, onExternalSignIn, externalError, onCancelExternal }: Props) {
  const id = useId()
  const { brand } = useBrand()
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [challenge, setChallenge] = useState<Extract<DialogEmailAuthStep, { step: 'code' }> | null>(null)
  const [busy, setBusy] = useState(false)
  const [externalPending, setExternalPending] = useState<'google' | 'sso' | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [google, setGoogle] = useState(false)
  const [optionsFailed, setOptionsFailed] = useState(false)
  const [retryOptions, setRetryOptions] = useState(0)
  const [resendAt, setResendAt] = useState(0)
  const [clock, setClock] = useState(() => Date.now())
  const mounted = useRef(false)
  const generation = useRef(0)
  const activeChallenge = useRef<string | null>(null)
  const pending = useRef(false)
  const finished = useRef(false)
  const codeInput = useRef<HTMLInputElement>(null)
  const emailInput = useRef<HTMLInputElement>(null)
  const external = Boolean(options.organizationId)

  function cancelChallenge(challengeId: string | null) {
    if (challengeId) void client.cancelEmail(challengeId).catch(() => { /* Expiring server-side challenges cannot authenticate without verification. */ })
  }
  function close() {
    generation.current += 1
    cancelChallenge(activeChallenge.current)
    activeChallenge.current = null
    onClose()
  }
  const dialog = usePilotDialog(close)
  useDialogViewport()

  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
      generation.current += 1
      if (!finished.current) cancelChallenge(activeChallenge.current)
      activeChallenge.current = null
    }
    // The provider remounts this dialog when the client or invitation changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  useEffect(() => {
    if (external) return
    let current = true
    void client.authOptions().then(result => {
      if (current) { setGoogle(result.google_enabled === true); setOptionsFailed(false) }
    }).catch(() => { if (current) setOptionsFailed(true) })
    return () => { current = false }
  }, [client, external, retryOptions])
  useEffect(() => {
    if (!challenge) return
    const timer = window.setInterval(() => setClock(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [challenge])
  useEffect(() => {
    if (challenge) codeInput.current?.focus({ preventScroll: true })
  }, [challenge])
  // Desktop visitors can type right away; phones wait for a tap so the keyboard
  // doesn't jump up over the sign-in options.
  useEffect(() => {
    if (!external && window.matchMedia?.('(pointer: fine)').matches) emailInput.current?.focus({ preventScroll: true })
    // Only on open.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function acceptStep(step: DialogEmailAuthStep, operation: number) {
    if (!mounted.current || generation.current !== operation) {
      if (step.step === 'code') cancelChallenge(step.challenge_id)
      return
    }
    if (step.step === 'complete') {
      finished.current = true; activeChallenge.current = null
      await onAuthenticated(step.return_to)
    } else if (step.step === 'redirect') {
      cancelChallenge(activeChallenge.current); activeChallenge.current = null
      await onExternalSignIn('sso', step.authorization_url)
    } else {
      activeChallenge.current = step.challenge_id
      setChallenge(step); setCode(''); setClock(Date.now())
      setResendAt(Date.now() + Math.max(0, step.resend_after) * 1000)
      setNotice(CODE_SENT)
    }
  }
  async function run(action: () => Promise<DialogEmailAuthStep | void>) {
    if (pending.current) return
    pending.current = true
    const operation = generation.current
    setBusy(true); setError(null); setNotice(null)
    try {
      const step = await action()
      if (step) await acceptStep(step, operation)
    } catch (caught) {
      if (mounted.current && generation.current === operation) {
        setError(safeError(caught))
        if (caught instanceof ApiRequestError && caught.code === 'email_challenge_expired') {
          cancelChallenge(activeChallenge.current); activeChallenge.current = null
          setChallenge(null); setCode('')
        }
      }
    } finally {
      if (mounted.current && generation.current === operation) { pending.current = false; setBusy(false) }
    }
  }
  async function chooseExternal(method: 'google' | 'sso') {
    if (pending.current) return
    const operation = generation.current
    setExternalPending(method)
    try { await run(() => onExternalSignIn(method)) } finally {
      if (mounted.current && generation.current === operation) setExternalPending(null)
    }
  }
  function cancelExternal() {
    generation.current += 1
    pending.current = false
    onCancelExternal?.()
    setExternalPending(null); setBusy(false); setError(null)
    setNotice('Stopped waiting for sign-in. You can continue with email or try again.')
  }
  function submit(event: FormEvent) {
    event.preventDefault()
    if (challenge) {
      if (/^\d{6}$/.test(code)) void run(() => client.verifyEmail(challenge.challenge_id, code))
    } else {
      const normalized = email.trim().toLowerCase()
      if (normalized) void run(() => client.startEmail({ ...options, email: normalized }))
    }
  }
  function differentEmail() {
    if (pending.current) return
    generation.current += 1
    cancelChallenge(activeChallenge.current); activeChallenge.current = null
    setChallenge(null); setCode(''); setError(null); setNotice(null)
    window.requestAnimationFrame(() => { if (mounted.current) emailInput.current?.focus({ preventScroll: true }) })
  }
  const resendSeconds = Math.max(0, Math.ceil((resendAt - clock) / 1000))
  const expired = challenge && Date.parse(challenge.expires_at) <= clock

  return createPortal(<div className="workos-sign-in-overlay">
    <div className="workos-sign-in-backdrop" aria-hidden="true" />
    <section ref={dialog} className="workos-sign-in-dialog" role="dialog" aria-modal="true" aria-labelledby={`${id}-title`} aria-describedby={`${id}-description`} tabIndex={-1}>
      <header><div><p className="eyebrow">{brand.product_name}</p><h2 id={`${id}-title`}>{challenge ? 'Check your email' : screen === 'sign-up' ? 'Join your invited workspace' : 'Welcome back'}</h2></div><button type="button" className="workos-sign-in-close" aria-label="Close" onClick={close}><svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true" focusable="false"><path d="M5 5l10 10M15 5L5 15" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" /></svg></button></header>
      <div className="pilot-dialog-body workos-sign-in-body">
        <p id={`${id}-description`}>{external ? 'Continue through your organization’s secure sign-in flow.' : challenge ? <>Enter the six-digit code sent to <strong>{challenge.email}</strong>.</> : 'Sign in with the email your program invited. Your saved information stays with your account.'}</p>
        {(error || externalError) && <p className="document-alert" role="alert">{externalError || error}</p>}
        <div className={`workos-sign-in-status${!busy && !externalPending && notice === CODE_SENT ? ' sr-only' : ''}`} role="status" aria-live="polite">{externalPending ? 'Complete sign-in with your provider. You can cancel and continue here.' : busy ? 'Checking your secure sign-in…' : notice}</div>
        {externalPending && onCancelExternal && <button type="button" className="secondary-button" onClick={cancelExternal}>Cancel sign-in</button>}
        {external ? <button type="button" className="button button--primary" disabled={busy} onClick={() => void chooseExternal('sso')}>Continue with your organization</button> : <>
          {!challenge && google && <><button type="button" className="secondary-button workos-google-button" disabled={busy} onClick={() => void chooseExternal('google')}><GoogleMark />Continue with Google</button><div className="workos-sign-in-divider"><span>or use email</span></div></>}
          <form className="workos-sign-in-form" onSubmit={submit} aria-busy={busy}>
            {challenge ? <><label htmlFor={`${id}-code`}>Sign-in code</label><input ref={codeInput} id={`${id}-code`} className="workos-code-input" name="code" type="text" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required value={code} disabled={busy} onChange={event => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))} aria-describedby={`${id}-code-help`} /><p id={`${id}-code-help`} className="workos-sign-in-note">{expired ? 'Your code has expired. Start again with your email.' : 'Use the latest code. You can paste all six digits.'}</p><button type="submit" className="button button--primary" disabled={busy || code.length !== 6 || Boolean(expired)}>{busy ? 'Verifying…' : 'Verify and sign in'}</button></> : <><label htmlFor={`${id}-email`}>Email address</label><input ref={emailInput} id={`${id}-email`} name="email" type="email" autoComplete="email" autoCapitalize="none" autoCorrect="off" spellCheck={false} required maxLength={254} value={email} disabled={busy} onChange={event => setEmail(event.target.value)} /><button type="submit" className="button button--primary" disabled={busy || !email.trim()}>{busy && !externalPending ? 'Sending code…' : 'Continue with email'}</button></>}
          </form>
          {challenge && <div className="workos-sign-in-secondary">{expired ? <button type="button" className="secondary-button" disabled={busy} onClick={differentEmail}>Start again</button> : <button type="button" className="secondary-button" disabled={busy || resendSeconds > 0} onClick={() => void run(() => client.resendEmail(challenge.challenge_id))}>{resendSeconds ? `Resend code in ${resendSeconds}s` : 'Resend code'}</button>}<button type="button" className="secondary-button" disabled={busy} onClick={differentEmail}>Use a different email</button></div>}
          {!challenge && optionsFailed && <div className="workos-sign-in-provider-retry"><p className="workos-sign-in-note">Other sign-in options could not be loaded. You can still continue with email.</p><button type="button" className="secondary-button" disabled={busy} onClick={() => setRetryOptions(value => value + 1)}>Retry sign-in options</button></div>}
        </>}
        <p className="workos-sign-in-note workos-sign-in-footer">Only invited accounts can open a workspace. Need access? Contact your program team.</p>
      </div>
    </section>
  </div>, document.body)
}
