export function changedInterestRateInput(original: number | null, draft: string) {
  const normalizedDraft = draft.trim()
  const changed = normalizedDraft === ''
    ? original !== null
    : original === null || Number(normalizedDraft) !== Number(original)

  return changed ? { interest_rate_percent: normalizedDraft || null } : {}
}
