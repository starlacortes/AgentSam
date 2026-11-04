import DOMPurify from 'dompurify'
import { marked } from 'marked'
import { useMemo } from 'react'

/**
 * Renders agent-written markdown. Deliverables come from LLM output, so the HTML is sanitized:
 * no scripts, event handlers, iframes, forms or styles, and links open in a new tab without a referrer.
 */
export function Markdown({ source }: { source: string }) {
  const html = useMemo(() => renderMarkdown(source), [source])
  return <div className="markdown" dangerouslySetInnerHTML={{ __html: html }} />
}

export function renderMarkdown(source: string): string {
  const raw = marked.parse(source, { async: false, gfm: true, breaks: false }) as string
  const clean = DOMPurify.sanitize(raw, {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ['style', 'form', 'input', 'button', 'iframe', 'object', 'embed', 'img', 'video', 'audio'],
    FORBID_ATTR: ['style'],
  })
  const template = document.createElement('template')
  template.innerHTML = clean
  for (const link of template.content.querySelectorAll('a')) {
    link.setAttribute('target', '_blank')
    link.setAttribute('rel', 'noopener noreferrer')
  }
  return template.innerHTML
}
