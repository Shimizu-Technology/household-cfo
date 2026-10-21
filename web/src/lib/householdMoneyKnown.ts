// A plan counts as entered once setup confirmed its amounts OR any category has a
// planned amount (plans built through Mia, an uploaded budget or category edits).
// Unknown must never be shown as $0, but a real plan must not read "Not entered" either.
export type PlanKnownInput = {
  workspace: { setup_status: { confirmed_fields: string[] } }
  budget: { annual_plan?: { rows?: { planned_total: number }[] } }
}

export function householdPlanKnown(data: PlanKnownInput): boolean {
  const confirmed = data.workspace.setup_status.confirmed_fields
  return (confirmed.includes('fixed_expenses') && confirmed.includes('flexible_spend'))
    || Boolean(data.budget.annual_plan?.rows?.some((row) => row.planned_total > 0))
}
