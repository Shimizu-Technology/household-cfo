import type { MiaActionItem } from '../api'
import { createContext, useCallback, useContext, useState } from 'react'

export type Editor = 'source' | 'schedule' | 'ending'
export const IncomeFormContext = createContext<{ active: Editor | null; locked: boolean; setActive: (active: Editor | null, requester: Editor) => void } | null>(null)
export function useIncomeForm(editor: Editor) {
  const shared = useContext(IncomeFormContext)
  const [localOpen, setLocalOpen] = useState(false)
  const sharedSet = shared?.setActive
  const setOpen = useCallback((open: boolean) => {
    if (sharedSet) sharedSet(open ? editor : null, editor)
    else setLocalOpen(open)
  }, [editor, sharedSet])
  return { open: shared ? shared.active === editor : localOpen, setOpen, blocked: Boolean(shared?.locked && shared.active !== editor) }
}
export type IncomeSourceFocusRequest = {
  key: number
  actionType: 'create_income_source' | 'update_income_source' | 'archive_income_source' | 'restore_income_source'
  sourceId: number | null
  payload: MiaActionItem['payload']
}

export type BudgetFocusRequest = {
  key: number
  operationKey: string
  actionType: MiaActionItem['action_type']
  categoryId: number | null
  months: number[]
  incomeScheduleEntryId: number | null
  payload: MiaActionItem['payload']
}
