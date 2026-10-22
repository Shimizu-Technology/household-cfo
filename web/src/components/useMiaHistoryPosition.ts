import { useCallback, useLayoutEffect, useRef, type RefObject } from 'react'

/** Restore the reader only after the newly revealed history has committed. */
export function useMiaHistoryPosition({ chatRef, visibleMessageCount, olderMessageCount, scope }: {
  chatRef: RefObject<HTMLElement | null>
  visibleMessageCount: number
  olderMessageCount: number
  scope: string
}) {
  const currentScope = useRef(scope)
  const pending = useRef<{ chat: HTMLElement; top: number; height: number; scope: string } | null>(null)

  useLayoutEffect(() => {
    currentScope.current = scope
    return () => { pending.current = null }
  }, [scope])

  useLayoutEffect(() => {
    const position = pending.current
    pending.current = null
    if (!position || position.scope !== scope || chatRef.current !== position.chat) return
    position.chat.scrollTop = position.top + position.chat.scrollHeight - position.height
  }, [chatRef, scope, visibleMessageCount, olderMessageCount])

  return useCallback(() => {
    const chat = chatRef.current
    if (!chat || currentScope.current !== scope) return false
    pending.current = { chat, scope, top: chat.scrollTop, height: chat.scrollHeight }
    return true
  }, [chatRef, scope])
}
