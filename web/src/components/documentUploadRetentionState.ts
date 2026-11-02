import { createContext, useContext, useState } from 'react'

export const RetentionContext = createContext<{
  clear: () => void
  files: Record<string, File | null>
  retain: (slot: string, file: File | null, completedFile?: File) => void
} | null>(null)

export function useRetainedDocumentFile(slot: string) {
  const retention = useContext(RetentionContext)
  const [localFile, setLocalFile] = useState<File | null>(null)
  const file = retention ? retention.files[slot] ?? null : localFile
  return [file, (next: File | null, completedFile?: File) => {
    if (retention) retention.retain(slot, next, completedFile)
    else setLocalFile(current => completedFile && current !== completedFile ? current : next)
  }] as const
}

export function useClearRetainedDocumentFiles() {
  return useContext(RetentionContext)?.clear ?? (() => undefined)
}
