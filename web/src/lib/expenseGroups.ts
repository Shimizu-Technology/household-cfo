import { createContext, useContext } from 'react'
import type { BudgetStackKey, MethodGroupNames } from '../api'

/** The four expense groups' names. Mirrors HouseholdFinance::ExpenseGroups in the API. Labels only: categories and totals never change. */
export const expenseGroupLabels: Record<MethodGroupNames, Record<BudgetStackKey, string>> = {
  plain: {
    non_discretionary: 'Must-pay bills',
    discretionary: 'Flexible spending',
    sinking_expected: 'Planned yearly costs',
    sinking_unexpected: 'Surprise fund',
  },
  method: {
    non_discretionary: 'Non-discretionary',
    discretionary: 'Discretionary',
    sinking_expected: 'Sinking Fund — Expected',
    sinking_unexpected: 'Sinking Fund — Unexpected',
  },
}

export const expenseGroupOrder: BudgetStackKey[] = ['non_discretionary', 'discretionary', 'sinking_expected', 'sinking_unexpected']

/** The program's group names for everything under the participant shell. Plain words unless the program chose her terms. */
export const ExpenseGroupNamesContext = createContext<MethodGroupNames>('plain')

export function useExpenseGroupLabels() {
  return expenseGroupLabels[useContext(ExpenseGroupNamesContext)]
}

export function useExpenseGroupNames() {
  return useContext(ExpenseGroupNamesContext)
}
