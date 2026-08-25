import type { ReactNode, RefObject } from 'react'
import type { FinancialDocumentImport, MiaMessage, MiaMessageAttachment } from '../api'

type ChatHistoryProps = {
  messages: MiaMessage[]
  totalMessageCount: number
  hiddenMessageCount: number
  olderMessageCount: number
  historyLoading: boolean
  miaLoading: boolean
  showScrollButton: boolean
  chatCardRef: RefObject<HTMLElement | null>
  onScroll: () => void
  onLoadEarlier: () => void
  onScrollLatest: () => void
  imports: FinancialDocumentImport[]
  onOpenLocal: (attachment: MiaMessageAttachment) => void
  onOpenImport: (documentImport: FinancialDocumentImport) => void
  onOpenImportId: (documentImportId: number) => void
  onReviewImportId: (documentImportId: number) => void
  reviewContent?: ReactNode
}

export function ChatHistory({
  messages,
  totalMessageCount,
  hiddenMessageCount,
  olderMessageCount,
  historyLoading,
  miaLoading,
  showScrollButton,
  chatCardRef,
  onScroll,
  onLoadEarlier,
  onScrollLatest,
  imports,
  onOpenLocal,
  onOpenImport,
  onOpenImportId,
  onReviewImportId,
  reviewContent,
}: ChatHistoryProps) {
  const remainingMessageCount = Math.max(0, hiddenMessageCount + olderMessageCount)

  return (
    <div className="chat-card-wrap">
      <article className="chat-card" ref={chatCardRef} aria-label="Mia conversation history" aria-live="polite" aria-busy={miaLoading || historyLoading} onScroll={onScroll}>
        {totalMessageCount === 0 && !miaLoading && (
          <div className="empty-chat-state">
            <span className="message-avatar" aria-hidden="true">M</span>
            <h3>Mia is ready when you are.</h3>
            <p>Ask what you need to decide next. Mia will use the approved household context already loaded here.</p>
          </div>
        )}
        {remainingMessageCount > 0 && (
          <button type="button" className="chat-history-load" disabled={historyLoading} onClick={onLoadEarlier}>
            {historyLoading ? 'Loading earlier messages' : `Load earlier messages (${remainingMessageCount} remaining)`}
          </button>
        )}
        {messages.map((message, index) => (
          <div className={`message-row ${message.role}`} key={messageKey(message, hiddenMessageCount + index)}>
            {message.role === 'assistant' && <span className="message-avatar" aria-hidden="true">M</span>}
            <div className={`message ${message.role}`}>
              <strong>{message.author}</strong>
              {messageContent(message, `${message.author}-${hiddenMessageCount + index}`)}
              {(message.attachments ?? []).length > 0 && (
                <MessageAttachmentList
                  attachments={message.attachments ?? []}
                  imports={imports}
                  onOpenLocal={onOpenLocal}
                  onOpenImport={onOpenImport}
                  onOpenImportId={onOpenImportId}
                  onReviewImportId={onReviewImportId}
                />
              )}
            </div>
          </div>
        ))}
        {miaLoading && (
          <div className="message-row assistant typing-row">
            <span className="message-avatar" aria-hidden="true">M</span>
            <div className="message assistant">
              <strong>Mia</strong>
              <div className="typing-dots" aria-label="Mia is thinking"><span /><span /><span /></div>
            </div>
          </div>
        )}
        {reviewContent}
      </article>
      {showScrollButton && totalMessageCount > 0 && (
        <button type="button" className="chat-scroll-bottom-button" aria-label="Scroll to latest Mia message" onClick={onScrollLatest}>
          <ScrollDownIcon />
          <span>Latest</span>
        </button>
      )}
    </div>
  )
}

function MessageAttachmentList({
  attachments,
  imports,
  onOpenLocal,
  onOpenImport,
  onOpenImportId,
  onReviewImportId,
}: {
  attachments: MiaMessageAttachment[]
  imports: FinancialDocumentImport[]
  onOpenLocal: (attachment: MiaMessageAttachment) => void
  onOpenImport: (documentImport: FinancialDocumentImport) => void
  onOpenImportId: (documentImportId: number) => void
  onReviewImportId: (documentImportId: number) => void
}) {
  return (
    <div className="message-attachment-list" aria-label="Message attachments">
      {attachments.map((attachment) => {
        const documentImport = attachment.document_import_id ? imports.find((candidate) => candidate.id === attachment.document_import_id) : null
        const hasImagePreview = Boolean(attachment.preview_url && browserPreviewableImage(attachment.content_type))
        const canOpen = Boolean(attachment.document_import_id || attachment.preview_url || documentImport?.source_available)
        const label = attachmentDisplayName(attachment)
        const effectiveStatus = documentImport?.status ?? attachment.status
        return (
          <div className={`message-attachment-entry ${hasImagePreview ? 'is-image' : ''}`} key={`${attachment.document_import_id ?? attachment.filename}-${attachment.filename}`}>
            <button
              type="button"
              className={`message-attachment-card ${hasImagePreview ? 'is-image' : ''}`}
              disabled={!canOpen}
              aria-label={`Preview ${label}`}
              onClick={() => {
                if (documentImport) onOpenImport(documentImport)
                else if (attachment.document_import_id) onOpenImportId(attachment.document_import_id)
                else if (attachment.preview_url) onOpenLocal(attachment)
              }}
            >
              {hasImagePreview ? <img src={attachment.preview_url} alt={label} loading="lazy" decoding="async" /> : <AttachmentIcon />}
              <span>{label}</span>
            </button>
            {attachment.document_import_id && (
              <button type="button" className="message-attachment-review" onClick={() => onReviewImportId(attachment.document_import_id!)}>
                {effectiveStatus === 'needs_review' ? 'Review draft' : 'Open import'}
              </button>
            )}
          </div>
        )
      })}
    </div>
  )
}

function messageKey(message: MiaMessage, index: number) {
  return message.id ? `server-${message.id}` : message.client_id ?? `${message.author}-${index}`
}

function messageContent(message: MiaMessage, keyPrefix: string) {
  const content = message.role === 'assistant' ? message.content.replace(/^Mia:\s*/i, '') : message.content
  const blocks: Array<{ type: 'paragraph' | 'list'; lines: string[] }> = []
  let startsNewParagraph = false

  for (const rawLine of content.split('\n')) {
    const line = rawLine.trim()
    if (!line) {
      startsNewParagraph = true
      continue
    }

    const listMatch = message.role === 'assistant' ? line.match(/^[-*]\s+(.+)$/) : null
    const type = listMatch ? 'list' : 'paragraph'
    const value = listMatch?.[1] ?? line
    const current = blocks.at(-1)
    if (current?.type === type && !(type === 'paragraph' && startsNewParagraph)) current.lines.push(value)
    else blocks.push({ type, lines: [value] })
    startsNewParagraph = false
  }

  return blocks.map((block, blockIndex) => block.type === 'list'
    ? <ul key={`${keyPrefix}-${blockIndex}`}>
      {block.lines.map((line, lineIndex) => <li key={`${keyPrefix}-${blockIndex}-${lineIndex}`}>{messageInlineText(line, message.role === 'assistant')}</li>)}
    </ul>
    : <p key={`${keyPrefix}-${blockIndex}`}>{messageInlineText(block.lines.join(' '), message.role === 'assistant')}</p>)
}

function messageInlineText(value: string, allowFormatting: boolean): ReactNode {
  if (!allowFormatting) return value

  return value.split(/(\*\*[^*]+\*\*)/g).map((part, index) => part.startsWith('**') && part.endsWith('**')
    ? <strong key={`${part}-${index}`}>{part.slice(2, -2)}</strong>
    : part)
}

function attachmentDisplayName(attachment: MiaMessageAttachment) {
  if (attachment.document_kind === 'receipt' && attachment.content_type.startsWith('image/')) return 'Receipt screenshot'
  if (attachment.document_kind === 'statement' && attachment.content_type.startsWith('image/')) return 'Statement screenshot'
  if (attachment.content_type.startsWith('image/')) return 'Screenshot'
  return attachment.document_kind.replace('_', ' ').replace(/^./, (letter) => letter.toUpperCase())
}

function browserPreviewableImage(contentType: string) {
  return ['image/jpeg', 'image/png', 'image/webp'].includes(contentType.toLowerCase())
}

function AttachmentIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 7.5h8M8 11.5h8M8 15.5h5" className="icon-stroke" /><path d="M6.5 3.5h8.25L18.5 7.25V20.5h-12v-17Z" className="icon-stroke" /><path d="M14.5 3.5v4h4" className="icon-stroke" /></svg>
}

function ScrollDownIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.75 9.5 12 14.75 17.25 9.5" className="icon-stroke" /></svg>
}
