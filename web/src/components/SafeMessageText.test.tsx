import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SafeMessageText } from './SafeMessageText'

describe('SafeMessageText', () => {
  it('preserves blank-line paragraphs and adjacent bullet items', () => {
    const markup = renderToStaticMarkup(
      <SafeMessageText
        content={'First paragraph line one.\nLine two.\n\nSecond paragraph.\n\n- Keep minimums current\n- Protect runway'}
        allowFormatting
      />,
    )

    expect(markup).toBe('<p>First paragraph line one. Line two.</p><p>Second paragraph.</p><ul><li>Keep minimums current</li><li>Protect runway</li></ul>')
  })

  it('renders formatting and markup-like input with React text nodes only', () => {
    const markup = renderToStaticMarkup(
      <SafeMessageText content={'**Saved fact:** <script>window.changed = true</script>'} allowFormatting />,
    )

    expect(markup).toContain('<strong>Saved fact:</strong>')
    expect(markup).toContain('&lt;script&gt;window.changed = true&lt;/script&gt;')
    expect(markup).not.toContain('<script>')
  })
})
