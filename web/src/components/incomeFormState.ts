import { createContext, useCallback, useContext, useState } from 'react'

export type Editor = 'source' | 'schedule'
export const IncomeFormContext = createContext<{ active: Editor | null; locked: boolean; setActive: (active: Editor | null) => void } | null>(null)
export function useIncomeForm(editor: Editor) {
  const shared = useContext(IncomeFormContext)
  const [localOpen, setLocalOpen] = useState(false)
  const sharedSet = shared?.setActive
  const setOpen = useCallback((open: boolean) => {
    if (sharedSet) sharedSet(open ? editor : null)
    else setLocalOpen(open)
  }, [editor, sharedSet])
  return { open: shared ? shared.active === editor : localOpen, setOpen, blocked: Boolean(shared?.locked && shared.active !== editor) }
}
