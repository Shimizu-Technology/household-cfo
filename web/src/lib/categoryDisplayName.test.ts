import { expect, it } from 'vitest'
import { categoryDisplayName, isCatchAllCategory } from './categoryDisplayName'
it('aliases only the matching group and separates a real category with that label', () => {
  expect(categoryDisplayName('Flexible spending')).toBe('Flexible spending')
  expect(categoryDisplayName('Flexible spending', 'non_discretionary')).toBe('Flexible spending')
  expect(categoryDisplayName('Everyday spending', 'discretionary')).toBe('Other everyday spending')
  expect(categoryDisplayName('Planned yearly costs', 'sinking_expected')).toBe('Other planned yearly costs')
  expect(categoryDisplayName('Other planned yearly costs', 'sinking_expected')).toBe('Other planned yearly costs (category)')
})

it('keeps labels unique across groups and through explicit category suffixes', () => {
  const names = ['Flexible spending', 'Other flexible spending', 'Other flexible spending (category)', 'Other flexible spending (category) (category)']
  const labels = names.map((name, index) => categoryDisplayName(name, index === 0 ? 'discretionary' : 'non_discretionary'))
  expect(new Set(labels.map(label => label.toLowerCase())).size).toBe(names.length)
  expect(isCatchAllCategory('Other flexible spending', 'discretionary')).toBe(false)
  expect(isCatchAllCategory('Flexible spending')).toBe(false)
  expect(isCatchAllCategory('Flexible spending', 'discretionary')).toBe(true)
})
