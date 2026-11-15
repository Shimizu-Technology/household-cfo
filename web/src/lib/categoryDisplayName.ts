import type { BudgetStackKey } from '../api'

const catchAllNames: Record<BudgetStackKey, string[]> = {
  non_discretionary: ['Must-pay bills', 'Fixed essentials'],
  discretionary: ['Flexible spending', 'Everyday spending'],
  sinking_expected: ['Planned yearly costs', 'Expected sinking fund'],
  sinking_unexpected: ['Surprise fund', 'Unexpected sinking fund'],
}
export const catchAllLabels: Record<BudgetStackKey, string> = {
  non_discretionary: 'Other must-pay bills',
  discretionary: 'Other flexible spending',
  sinking_expected: 'Other planned yearly costs',
  sinking_unexpected: 'Other surprise costs',
}
type CategoryContext = { id: number; name: string; stack_key: BudgetStackKey }
// Presentation only: the saved category and linked expense item keep their names.
export function categoryDisplayName(name: string, stack?: BudgetStackKey, rows?: readonly CategoryContext[]) {
  if (!stack) return name
  const candidates = rows?.filter(row => row.stack_key === stack && isCatchAllCategory(row.name, stack)).sort((a, b) => a.id - b.id)
  const catchAll = candidates ? candidates[0]?.name : name
  if (isCatchAllCategory(name, stack) && catchAll === name) {
    let label = catchAllLabels[stack]
    // An explicitly saved label always wins; only the remainder gets a suffix.
    while (rows?.some(row => row.stack_key === stack && row.name !== name && row.name.toLowerCase() === label.toLowerCase())) label += ' (remainder)'
    return label
  }
  return name
}
export function isCatchAllCategory(name: string, stack?: BudgetStackKey) {
  return Boolean(stack && catchAllNames[stack].some(candidate => candidate.toLowerCase() === name.toLowerCase()))
}
