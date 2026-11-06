import type { PersonaConfiguration } from '../api'

type Phrase = Pick<PersonaConfiguration['phrases'][number], 'meaning' | 'allowed_contexts' | 'frequency' | 'caution'>
const contexts: Record<string, string> = {
  greeting: 'when welcoming someone', verified_milestone: 'after a confirmed milestone',
  emotional_support: 'when someone needs encouragement', repeated_pattern: 'when a spending habit comes up again',
  routine: 'during everyday check-ins', general: 'during everyday coaching',
}
const frequency: Record<string, string> = {
  very_rare: 'Only once in a long while', rare: 'Occasionally', sparing: 'From time to time', as_needed: 'Whenever the situation fits',
}
export function PhraseUse({ phrase }: { phrase: Phrase }) {
  return <><p>{phrase.meaning}</p><p>{frequency[phrase.frequency] ?? 'Occasionally'}, {phrase.allowed_contexts.filter(context => context !== 'crisis').map(context => contexts[context] ?? context.replaceAll('_', ' ')).join(' or ')}. Never during crisis support.</p>{phrase.caution && <p>{phrase.caution}</p>}</>
}
