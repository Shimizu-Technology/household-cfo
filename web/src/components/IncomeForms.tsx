import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react'

type Editor = 'source' | 'schedule'
const IncomeFormContext = createContext<{ active: Editor | null; locked: boolean; setActive: (active: Editor | null) => void } | null>(null)

/** Keep the saved sources visible while opening only one income editor. */
export function IncomeForms({ children, locked }: { children: ReactNode; locked: boolean }) {
  const [active, setActive] = useState<Editor | null>(null)
  const select = useCallback((next: Editor | null) => {
    setActive(current => locked && next !== null && current !== next ? current : next)
  }, [locked])
  const value = useMemo(() => ({ active, locked, setActive: select }), [active, locked, select])
  return <IncomeFormContext.Provider value={value}>{children}</IncomeFormContext.Provider>
}

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
