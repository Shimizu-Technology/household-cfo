import { expect, it } from 'vitest'
import { categoryDisplayName } from './categoryDisplayName'
it('aliases only the matching group and separates a real category with that label', () => {
  expect(categoryDisplayName('Flexible spending')).toBe('Flexible spending')
  expect(categoryDisplayName('Flexible spending', 'non_discretionary')).toBe('Flexible spending')
  expect(categoryDisplayName('Everyday spending', 'discretionary')).toBe('Other everyday spending')
  expect(categoryDisplayName('Planned yearly costs', 'sinking_expected')).toBe('Other planned yearly costs')
  expect(categoryDisplayName('Other planned yearly costs', 'sinking_expected')).toBe('Other planned yearly costs (category)')
})
