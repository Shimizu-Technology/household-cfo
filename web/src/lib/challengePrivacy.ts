export type PrivacyScope = { user_id: number; household_id: number }
export type PrivateProgram = { id: number; cohort_id: number; program_name: string; starts_on: string; ends_on: string; time_zone: string; status: string }
export type RecordType = 'document_source' | 'source_review_version' | 'savings_entry_version' | 'savings_plan_version' | 'chat_message'
export type SelectedRecord = { record_type: RecordType; record_id: number }
export type PrivacyCandidate = SelectedRecord & { preview: Record<string, string | number | boolean | null>; shares_entire_record: true }
export type PrivatePage<T> = { records: T[]; next_cursor: number | null; actor_scope: PrivacyScope }
export type SharingKind = 'coach_summary' | 'selected_details' | 'sponsor_aggregate'
export type PrivacyGrant = { id: number; kind: SharingKind; recipient_user_id: number | null; granted: boolean; selected_records: SelectedRecord[]; expires_at: string | null; policy_version: string; lock_version: number }
export type SupportTicket = { id: number; recipient_user_id: number; issue_kind: string; message: string; selected_records: SelectedRecord[]; status: string; lock_version: number; created_at: string }
export type SupportAccess = { id: number; challenge_support_ticket_id: number; recipient_user_id: number; selected_records: SelectedRecord[]; reason: string; expires_at: string; revoked_at: string | null; lock_version: number }
export type ErasableReflection = { id: number; current_version_id: number | null; lock_version: number; created_at: string; erased_at: string | null }
export type PrivacyState = { enrollment_id: number; actor_scope: PrivacyScope; policy_version: string; grants: PrivacyGrant[]; support_requests: SupportTicket[]; support_access: SupportAccess[]; recipients: { id: number; name: string; role: string }[]; erasable_reflections: ErasableReflection[]; reflections_next_cursor: number | null; downloaded_copies_retrievable: false }
export type SourceLease = { document_import_id: number; source_available: boolean; latest_authorized_expiry: string | null; affected_uses: { id: number; enrollment_id: number; expires_at: string; revoked: boolean }[]; expected_affected_uses_digest: string; disclosure_version: string; expected_expires_at: string; expected_use_id: number | null; expected_lock_version: number; approved_financial_records_retained: true; provider_backup_retention_verified: false; downloaded_copies_retrievable: false }
export type ReminderPreference = { id: number | null; channel: 'in_app' | 'email'; enabled: boolean; local_time: string; quiet_start: string; quiet_end: string; policy_version: string; lock_version: number }
export type RemindersState = { enrollment_id: number; actor_scope: PrivacyScope; time_zone: string; preferences: ReminderPreference[]; reminder: { id: number; lock_version: number; local_on: string; title: string; body: string } | null; email_delivery_enabled: boolean; dismissal_is_check_in: false }
export type PrivacyAction = 'consent' | 'support_request' | 'support_grant' | 'support_revoke' | 'source_authorize' | 'source_revoke'
export type PrivateAction = PrivacyAction | 'preference' | 'dismiss' | 'erase'
export type RequestIdentity = { scope: PrivacyScope; enrollmentId: number; action: PrivateAction; key: string; reflectionId?: number }
export type PrivateStatus = { state: 'committed' | 'unknown' | 'in_flight'; can_retry?: boolean; actor_scope?: PrivacyScope }
export interface PrivacyApi {
  controls(cursor?: number | null, signal?: AbortSignal): Promise<PrivatePage<PrivateProgram>>
  privacy(enrollmentId: number, cursor?: number | null, signal?: AbortSignal): Promise<PrivacyState>
  candidates(enrollmentId: number, type: RecordType, cursor?: number | null, signal?: AbortSignal): Promise<PrivatePage<PrivacyCandidate>>
  source(enrollmentId: number, sourceId: number, signal?: AbortSignal): Promise<SourceLease>
  reminders(enrollmentId: number, signal?: AbortSignal): Promise<RemindersState>
  mutate(identity: RequestIdentity, input: object, signal?: AbortSignal): Promise<unknown>
  status(identity: RequestIdentity, signal?: AbortSignal): Promise<PrivateStatus>
}
export const samePrivacyScope = (a: PrivacyScope, b: PrivacyScope) => a.user_id === b.user_id && a.household_id === b.household_id
export function assertPrivacyScope(value: { actor_scope?: PrivacyScope }, expected: PrivacyScope) {
  if (!value.actor_scope || !samePrivacyScope(value.actor_scope, expected)) throw new Error('This private response belongs to a different account. Close and reopen your controls.')
}
export const recordLabels: Record<RecordType, string> = { document_source: 'Original statements', source_review_version: 'Reviewed source rows', savings_entry_version: 'Savings entries', savings_plan_version: 'Accepted plans', chat_message: 'Chat messages' }
export function candidateLabel(candidate: PrivacyCandidate): string {
  const p = candidate.preview
  return [p.filename, p.merchant, p.role, p.effective_on, p.posted_on, p.approved_at, p.created_at, p.content_excerpt,
    p.signed_cents === undefined ? undefined : `${p.signed_cents} cents`, p.signed_amount_cents === undefined ? undefined : `${p.signed_amount_cents} cents`,
    p.target_cents === undefined ? undefined : `Target ${p.target_cents === null ? 'postponed' : `${p.target_cents} cents`}`, p.event_type].filter((part) => part !== undefined && part !== null).join(' · ') || `Record ${candidate.record_id}`
}
