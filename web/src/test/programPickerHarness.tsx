import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { ParticipantProgramPicker } from '../components/ParticipantProgramPicker'
import '../index.css'
import '../App.css'

export function Harness() {
  const [chosen, setChosen] = useState<number>()
  return <main style={{ padding: 16, maxWidth: 800, margin: 'auto' }}>
    <h1>Synthetic program selection</h1>
    <p>Fictional metadata only. No enrollment or financial records.</p>
    <ParticipantProgramPicker actorId={7} onChoose={setChosen} />
    <p role="status">{chosen ? `Explicit program choice: ${chosen}` : 'No explicit program choice yet.'}</p>
  </main>
}
createRoot(document.getElementById('root')!).render(<Harness />)
