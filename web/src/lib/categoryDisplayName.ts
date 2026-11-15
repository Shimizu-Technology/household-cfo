import type { BudgetStackKey } from '../api'

const catchAllNames: Record<BudgetStackKey, string[]> = {
  non_discretionary: ['Must-pay bills', 'Fixed essentials'],
  discretionary: ['Flexible spending', 'Everyday spending'],
  sinking_expected: ['Planned yearly costs', 'Expected sinking fund'],
  sinking_unexpected: ['Surprise fund', 'Unexpected sinking fund'],
}
// Presentation only: the saved category and linked expense item keep their names.
export function categoryDisplayName(name: string, stack?: BudgetStackKey) {
  if (!stack) return name
  if ((catchAllNames[stack] ?? []).some(candidate => candidate.toLowerCase() === name.toLowerCase())) return `Other ${name.toLowerCase()}`
  // Keep an explicitly named category distinct from the group's remainder.
  if ((catchAllNames[stack] ?? []).some(candidate => `other ${candidate.toLowerCase()}` === name.toLowerCase())) return `${name} (category)`
  return name
}
export function isCatchAllCategory(name: string, stack?: BudgetStackKey) {
  return categoryDisplayName(name, stack) !== name
}
