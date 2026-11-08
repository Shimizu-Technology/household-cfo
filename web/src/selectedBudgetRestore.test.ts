import { readFileSync } from 'node:fs'
import ts from 'typescript'
import { expect, it, vi } from 'vitest'

it('refreshes the active report period after restoring a different-year draft', async () => {
  const source = readFileSync(new URL('./App.tsx', import.meta.url), 'utf8')
  const start = source.indexOf('      await restoreSelectedBudgetPlan(workspace.budget)', source.indexOf('async function handleConfirmTransactionDraft'))
  const end = source.indexOf('      void refreshDocumentImports', start)
  const js = ts.transpile(source.slice(start, end), { target: ts.ScriptTarget.ES2022 })
  const refresh = vi.fn()
  const period = { current: { startsOn: '2026-11-01', endsOn: '2026-11-30' } }
  const run = new Function('restoreSelectedBudgetPlan', 'workspace', 'selectedBudgetPeriodRef', 'refreshSpendingReport', 'refreshSpendingReportForBudget', 'budgetView', 'draftMonthIndex', `return (async () => { ${js} })()`)
  await run(async () => { period.current = { startsOn: '2027-01-01', endsOn: '2027-01-31' } }, { budget: { annual_plan: { year: 2025 } } }, period, refresh, vi.fn(), { monthIndex: 0 }, 0)
  expect(refresh).toHaveBeenCalledWith({ startsOn: '2027-01-01', endsOn: '2027-01-31' })
})
