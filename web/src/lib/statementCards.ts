import type { FinancialDocumentImport } from '../api'
import { documentNeedsReview } from './documentReview'
import { sourceReviewMode } from './sourceReview'

// Which uploaded statements get a card in the chat, and what stage each is at.
export type StatementCardStage = 'reading' | 'failed' | 'review' | 'approved'
export type StatementCardEntry = { documentImport: FinancialDocumentImport; stage: StatementCardStage }

const DAY = 24 * 3600 * 1000
/** A statement that still needs her stays in the chat for a while; one she has approved only long enough to be seen. */
const OPEN_FOR = 14 * DAY
const APPROVED_FOR = 2 * DAY
/** Three months is the biggest set Mia lines up at once; anything more is on the Statements screen. */
export const MAX_STATEMENT_CARDS = 4

const PROCESSING = new Set(['uploaded', 'processing'])

function stageOf(documentImport: FinancialDocumentImport): StatementCardStage | null {
  if (documentImport.document_kind !== 'statement' || documentImport.context_paused_by_restart) return null
  if (PROCESSING.has(documentImport.status)) return 'reading'
  if (documentImport.status === 'failed') return 'failed'
  // Only a statement read into reviewable lines has a card to answer; older, expense-only reads stay on the Statements screen.
  if (sourceReviewMode(documentImport) !== 'typed') return null
  return documentNeedsReview(documentImport) ? 'review' : 'approved'
}

/** By the month each covers, so three months read August, September, October wherever they were uploaded from. */
export function statementCardEntries(imports: FinancialDocumentImport[], now: number): StatementCardEntry[] {
  return imports.flatMap((documentImport): StatementCardEntry[] => {
    const stage = stageOf(documentImport)
    if (!stage) return []
    const at = Date.parse(documentImport.processed_at ?? documentImport.updated_at)
    const age = Number.isFinite(at) ? now - at : 0
    if (stage !== 'reading' && age > (stage === 'approved' ? APPROVED_FOR : OPEN_FOR)) return []
    return [{ documentImport, stage }]
  }).sort((left, right) => (left.documentImport.period_start_on ?? '').localeCompare(right.documentImport.period_start_on ?? '') || left.documentImport.id - right.documentImport.id)
}

/** How many calendar months the approved statements cover, so Mia can say "your last 3 months". */
export function monthsCovered(imports: FinancialDocumentImport[]): number {
  const months = new Set<string>()
  for (const documentImport of imports) {
    const start = documentImport.period_start_on ?? documentImport.document_date
    const end = documentImport.period_end_on ?? start
    if (!start || !end) continue
    const last = end.slice(0, 7)
    let cursor = start.slice(0, 7)
    for (let guard = 0; guard < 24 && cursor <= last; guard += 1) {
      months.add(cursor)
      const [year, month] = cursor.split('-').map(Number)
      cursor = month === 12 ? `${year + 1}-01` : `${year}-${String(month + 1).padStart(2, '0')}`
    }
  }
  return months.size
}
