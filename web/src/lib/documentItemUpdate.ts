export function changedInterestRateInput(original: number | null, draft: string) {
  const normalizedDraft = draft.trim()
  const changed = normalizedDraft === ''
    ? original !== null
    : original === null || Number(normalizedDraft) !== Number(original)

  return changed ? { interest_rate_percent: normalizedDraft || null } : {}
}

export function changedDebtMoneyInputs(originalBalance: number | null, originalPayment: number | null, balance: string, payment: string) {
  const changedMoney = (original: number | null, draft: string) => {
    const normalized = draft.trim()
    if (normalized === '') return original === null ? undefined : null
    return normalized
  }
  const changedBalance = changedMoney(originalBalance, balance)
  const changedPayment = changedMoney(originalPayment, payment)
  return {
    ...(changedBalance === undefined ? {} : { balance: changedBalance }),
    ...(changedPayment === undefined ? {} : { payment: changedPayment }),
  }
}
