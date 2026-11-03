// File sizes for people, not for logs: "Under 1 KB", "48 KB", "2.4 MB".
export function formatFileSize(bytes: number) {
  if (bytes < 1024) return 'Under 1 KB'
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${Number((bytes / 1024 / 1024).toFixed(1))} MB`
}
