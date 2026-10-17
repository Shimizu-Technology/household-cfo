const FIRST_SETUP_FIELDS = ['household_name', 'primary_goal', 'primary_income', 'fixed_expenses', 'flexible_spend'] as const

type FirstSetupDraft = Partial<Record<(typeof FIRST_SETUP_FIELDS)[number], string | number | null>>

/** True when any of the five first-run fields differs from what is saved (drives the reload warning). */
export function firstSetupHasUnsavedChanges(draft: FirstSetupDraft, saved: FirstSetupDraft) {
  return FIRST_SETUP_FIELDS.some((key) => String(draft[key] ?? '') !== String(saved[key] ?? ''))
}
