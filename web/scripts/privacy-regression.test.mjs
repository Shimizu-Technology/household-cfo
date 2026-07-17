import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const analytics = readFileSync(resolve(__dirname, '../src/lib/analytics.ts'), 'utf8')
const app = readFileSync(resolve(__dirname, '../src/App.tsx'), 'utf8')

assert.ok(
  analytics.includes('$current_url: `${window.location.origin}${window.location.pathname}`'),
  'analytics pageviews must omit query strings and hashes',
)
assert.ok(!analytics.includes('$current_url: window.location.href'), 'raw browser URLs must never enter analytics')
assert.ok(!analytics.includes('$hash:'), 'route hashes must not be captured')
assert.ok(analytics.includes('maskAllInputs: true'), 'session replay must mask every input')
assert.ok(analytics.includes("maskTextSelector: '*'"), 'session replay must mask rendered text')
assert.ok(analytics.includes('autocapture: false'), 'PostHog autocapture must stay disabled')

for (const forbiddenProperty of [
  'household_name:',
  'readiness_label:',
  'message_content:',
  'account_number:',
]) {
  assert.ok(!analytics.includes(forbiddenProperty), `analytics helper must not include ${forbiddenProperty}`)
}
assert.ok(!app.includes('amount_bucket:'), 'financial amount buckets must not enter analytics events')
assert.ok(!app.includes('profile_complete:'), 'financial profile completeness must not enter pageview analytics')

for (const requiredEvent of [
  'workspace_setup_saved',
  'mia_message_sent',
  'document_import_upload_${status}',
  'transaction_draft_presented_in_chat',
  'transaction_draft_confirmed',
  'pilot_workflow_failed',
  'pilot_review_completed',
]) {
  assert.ok(`${analytics}\n${app}`.includes(requiredEvent), `pilot funnel must include ${requiredEvent}`)
}

console.log('privacy regression checks passed')
