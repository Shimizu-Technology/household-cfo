import { useEffect, useRef, useState } from 'react'
import { updateHomeView, type HomeView, type HomeViewChoice } from '../api'

export function useHomeView({ choice, onChoice, announce }: {
  choice: HomeViewChoice | undefined
  onChoice: (choice: HomeViewChoice) => void
  announce: (message: string) => void
}) {
  const [homeViewSaving, setSaving] = useState(false)
  const [homeViewError, setError] = useState<string | null>(null)
  // Her last saved choice. A workspace reload that started before the save still
  // carries the old preference; keep hers on top of it instead of discarding the
  // reload, which also carries fresh money after a statement or debt change.
  const saved = useRef<HomeView | null | undefined>(undefined)
  useEffect(() => {
    const kept = saved.current
    if (kept === undefined || !choice || choice.chosen === kept) return
    onChoice({ ...choice, chosen: kept, effective: kept ?? choice.program })
  }, [choice, onChoice])
  async function changeHomeView(view: HomeView) {
    if (!choice || homeViewSaving) return
    setError(null)
    onChoice({ ...choice, chosen: view, effective: view })
    setSaving(true)
    try {
      const result = await updateHomeView(view)
      saved.current = result.home_view.chosen
      onChoice(result.home_view)
      announce(view === 'year' ? 'Home now shows your year first.' : 'Home now shows this month first.')
    } catch {
      onChoice(choice)
      const message = 'Home view could not be saved right now. Please try again.'
      setError(message)
      announce(message)
    } finally {
      setSaving(false)
    }
  }
  return { changeHomeView, homeViewSaving, homeViewError }
}
