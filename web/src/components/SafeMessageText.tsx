import type { ReactNode } from 'react'

type SafeMessageTextProps = {
  content: string
  allowFormatting?: boolean
  stripMiaPrefix?: boolean
  stripAuthorPrefix?: string
}

export function SafeMessageText({ content, allowFormatting = false, stripMiaPrefix = false, stripAuthorPrefix }: SafeMessageTextProps) {
  const authorPrefix = stripAuthorPrefix ?? (stripMiaPrefix ? 'Mia' : null)
  const normalizedContent = authorPrefix && content.slice(0, authorPrefix.length + 1).toLowerCase() === `${authorPrefix}:`.toLowerCase()
    ? content.slice(authorPrefix.length + 1).trimStart()
    : content
  const blocks: Array<{ type: 'paragraph' | 'list'; lines: string[] }> = []
  let startsNewParagraph = false

  for (const rawLine of normalizedContent.split('\n')) {
    const line = rawLine.trim()
    if (!line) {
      startsNewParagraph = true
      continue
    }

    const listMatch = allowFormatting ? line.match(/^[-*]\s+(.+)$/) : null
    const type = listMatch ? 'list' : 'paragraph'
    const value = listMatch?.[1] ?? line
    const current = blocks.at(-1)
    if (current?.type === type && !(type === 'paragraph' && startsNewParagraph)) current.lines.push(value)
    else blocks.push({ type, lines: [value] })
    startsNewParagraph = false
  }

  return blocks.map((block, blockIndex) => block.type === 'list'
    ? <ul key={`list-${blockIndex}`}>
      {block.lines.map((line, lineIndex) => <li key={`${blockIndex}-${lineIndex}`}>{inlineText(line, allowFormatting)}</li>)}
    </ul>
    : <p key={`paragraph-${blockIndex}`}>{inlineText(block.lines.join(' '), allowFormatting)}</p>)
}

function inlineText(value: string, allowFormatting: boolean): ReactNode {
  if (!allowFormatting) return value

  return value.split(/(\*\*[^*]+\*\*)/g).map((part, index) => part.startsWith('**') && part.endsWith('**')
    ? <strong key={`${part}-${index}`}>{part.slice(2, -2)}</strong>
    : part)
}
