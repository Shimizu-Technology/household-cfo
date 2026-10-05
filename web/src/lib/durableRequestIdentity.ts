// Only request-routing metadata belongs in these journals; financial inputs stay in memory.
export function retainRequestIdentity(storageKey: string, serialized: string): boolean {
  try {
    sessionStorage.setItem(storageKey, serialized)
    return sessionStorage.getItem(storageKey) === serialized
  } catch { return false }
}
export const requestStorageError = 'This browser cannot retain the request identity. No change was submitted. Allow session storage before trying again.'
