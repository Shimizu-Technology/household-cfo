import { expect, it } from 'vitest'
import { categoryDisplayName, isCatchAllCategory } from './categoryDisplayName'
it('aliases only the matching group and separates a real category with that label', () => {
  expect(categoryDisplayName('Flexible spending')).toBe('Flexible spending')
  expect(categoryDisplayName('Flexible spending', 'non_discretionary')).toBe('Flexible spending')
  expect(categoryDisplayName('Everyday spending', 'discretionary')).toBe('Other flexible spending')
  expect(categoryDisplayName('Planned yearly costs', 'sinking_expected')).toBe('Other planned yearly costs')
  expect(categoryDisplayName('Other planned yearly costs', 'sinking_expected')).toBe('Other planned yearly costs')
})

it('keeps labels unique within a group and through explicit category suffixes', () => {
  const names = ['Flexible spending', 'Other flexible spending', 'Other flexible spending (category)', 'Other flexible spending (category) (category)']
  const rows = names.map((name, id) => ({ name, id, stack_key: 'discretionary' as const }))
  const labels = names.map(name => categoryDisplayName(name, 'discretionary', rows))
  expect(new Set(labels.map(label => label.toLowerCase())).size).toBe(names.length)
  expect(isCatchAllCategory('Other flexible spending', 'discretionary')).toBe(false)
  expect(isCatchAllCategory('Flexible spending')).toBe(false)
  expect(isCatchAllCategory('Flexible spending', 'discretionary')).toBe(true)
})

it('uses group words and reserves one remainder without renaming a later household category', () => {
  expect(categoryDisplayName('Fixed essentials', 'non_discretionary')).toBe('Other must-pay bills')
  expect(categoryDisplayName('Expected sinking fund', 'sinking_expected')).toBe('Other planned yearly costs')
  expect(categoryDisplayName('Unexpected sinking fund', 'sinking_unexpected')).toBe('Other surprise costs')
  const rows = [{ id: 1, name: 'Flexible spending', stack_key: 'discretionary' as const }, { id: 2, name: 'Everyday spending', stack_key: 'discretionary' as const }, { id: 3, name: 'Other flexible spending', stack_key: 'discretionary' as const }]
  const labels = rows.map(row => categoryDisplayName(row.name, row.stack_key, rows))
  expect(labels).toEqual(['Other flexible spending (remainder)', 'Everyday spending', 'Other flexible spending'])
  expect(new Set(labels).size).toBe(3)
})
