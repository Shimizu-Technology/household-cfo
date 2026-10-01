export type MemoryDraft = {
  category: string
  display_value: string
  sensitivity: string
}

export type MemoryRequestKeyState = {
  fingerprint: string
  requestKey: string
}

export function memoryDraftFingerprint(draft: MemoryDraft) {
  return JSON.stringify({
    category: draft.category,
    display_value: draft.display_value.trim(),
    sensitivity: draft.sensitivity,
  })
}

export function resolveMemoryRequestKey(
  current: MemoryRequestKeyState | null,
  draft: MemoryDraft,
  generate: () => string,
): MemoryRequestKeyState {
  const fingerprint = memoryDraftFingerprint(draft)
  if (current?.fingerprint === fingerprint) return current

  return { fingerprint, requestKey: generate() }
}
