import { useState, type RefObject } from 'react'
import { updateHomeView, type HomeView, type HomeViewChoice } from '../api'

export function useHomeView({ choice, generationRef, onChoice, announce }: {
  choice: HomeViewChoice | undefined
  generationRef: RefObject<number>
  onChoice: (choice: HomeViewChoice) => void
  announce: (message: string) => void
}) {
  const [homeViewSaving, setSaving] = useState(false)
  const [homeViewError, setError] = useState<string | null>(null)
  async function changeHomeView(view: HomeView) {
    if (!choice || homeViewSaving) return
    setError(null)
    onChoice({ ...choice, chosen: view, effective: view })
    setSaving(true)
    try {
      const saved = await updateHomeView(view)
      // Every workspace reload captures this generationRef before fetching. A
      // payload from before this save must not restore the old preference.
      generationRef.current += 1
      onChoice(saved.home_view)
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
