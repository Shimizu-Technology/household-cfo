// Reads a pasted list of email addresses (commas, spaces, new lines, or "Name <a@b.c>").
// Returns the clean unique addresses and a plain note for each entry it could not use.
const VALID_EMAIL = /^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/

export const MAX_INVITES_AT_ONCE = 100

export function parseInviteEmails(text: string): { emails: string[]; problems: string[] } {
  const entries = text.split(/[,;\n]+/)
    .flatMap(line => line.match(/[^<>]*<[^<>]*>|[^<>]+|[<>]/g) ?? [])
    // Addresses typed ahead of a "Name <address>" are their own entries, not part of the name.
    .flatMap(segment => {
      const named = segment.match(/^([^<>]*)(<[^<>]*>)$/)
      if (!named) return [segment]
      const words = named[1].trim().split(/\s+/).filter(Boolean)
      return [...words.filter(word => word.includes('@')), `${words.filter(word => !word.includes('@')).join(' ')} ${named[2]}`.trim()]
    })
    .flatMap(line => line.includes('<') || line.includes('>') || (line.match(/@/g)?.length === 1) ? [line.trim()] : line.trim().split(/\s+/))
    .filter(Boolean)
  const emails: string[] = []
  const problems: string[] = []
  for (const entry of entries) {
    const named = entry.match(/^[^<>]+<([^<>]+)>$/)
    const address = (named?.[1] ?? entry).trim().toLowerCase()
    if (address.length > 254 || !VALID_EMAIL.test(address)) problems.push(`“${entry}” isn’t a complete email address.`)
    else if (emails.includes(address)) problems.push(`${address} is listed twice. It will be invited once.`)
    else emails.push(address)
  }
  return { emails, problems }
}
