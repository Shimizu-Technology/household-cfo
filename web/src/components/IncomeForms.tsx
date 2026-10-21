import { useCallback, useMemo, useState, type ReactNode } from 'react'

import { IncomeFormContext, type Editor } from './incomeFormState'

/** Keep the saved sources visible while opening only one income editor. */
export function IncomeForms({ children, locked }: { children: ReactNode; locked: boolean }) {
  const [active, setActive] = useState<Editor | null>(null)
  const select = useCallback((next: Editor | null) => {
    setActive(current => locked && next !== null && current !== next ? current : next)
  }, [locked])
  const value = useMemo(() => ({ active, locked, setActive: select }), [active, locked, select])
  return <IncomeFormContext.Provider value={value}>{children}</IncomeFormContext.Provider>
}
