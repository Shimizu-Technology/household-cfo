export type MoneyTopic = 'income' | 'spending' | 'debt' | 'accounts' | 'goals' | 'statements'
export const moneyTopics: { id: MoneyTopic; label: string }[] = [
  { id: 'income', label: 'Income' },
  { id: 'spending', label: 'Spending' },
  { id: 'debt', label: 'Debt' },
  { id: 'accounts', label: 'Accounts' },
  { id: 'goals', label: 'Goals' },
  { id: 'statements', label: 'Statements' },
]

export function moneyTopicForOperation(operationKey: string, actionType?: string): MoneyTopic | null {
  if (operationKey.startsWith('income.source.') || operationKey.startsWith('income.schedule.')) return 'income'
  if (operationKey.startsWith('debt.') || actionType?.includes('debt')) return 'debt'
  if (operationKey.startsWith('account.') || actionType?.endsWith('_account')) return 'accounts'
  if (operationKey.startsWith('goal.record.') || actionType?.endsWith('_goal')) return 'goals'
  return null
}
