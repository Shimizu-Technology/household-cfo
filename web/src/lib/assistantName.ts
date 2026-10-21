// A persona's assistant name doubles as its Coach Studio label, so coaches
// write names like "Mia for Mrs. Mel BOG". Participants meet the assistant by
// name ("Mia"). Keep this rule in step with api/app/services/mia/assistant_display_name.rb.
const LABEL_SEPARATOR = /\s+(?:for|from)\s+|\s+[-–—|·:]\s+|\s*[([]/i
const MAX_LENGTH = 32

export function shortAssistantName(name: string | null | undefined) {
  const full = (name ?? '').replace(/\s+/g, ' ').trim()
  const first = full.split(LABEL_SEPARATOR)[0]?.trim() ?? ''
  if (!first || first.length > MAX_LENGTH) return full
  return first
}
