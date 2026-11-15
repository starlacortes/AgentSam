import DOMPurify from 'dompurify'
import { marked } from 'marked'
import { useMemo, type MouseEvent } from 'react'

export interface CodeTools {
  copyLabel: string
  copiedLabel: string
  previewLabel: string
  /** Shown on html/svg blocks when set. */
  onPreview?: (language: string, code: string) => void
  canPreview?: (language: string) => boolean
}

/**
 * Renders agent-written markdown. Deliverables come from LLM output, so the HTML is sanitized:
 * no scripts, event handlers, iframes, forms or styles, and links open in a new tab without a referrer.
 * With `codeTools`, fenced code blocks get a language label and Copy/Preview buttons, added after sanitizing.
 */
export function Markdown({ source, codeTools }: { source: string; codeTools?: CodeTools }) {
  const html = useMemo(() => renderMarkdown(source, codeTools), [source, codeTools])
  const click = (event: MouseEvent<HTMLDivElement>) => {
    if (!codeTools) return
    const button = (event.target as HTMLElement).closest<HTMLButtonElement>('button[data-code-action]')
    if (!button) return
    const block = button.closest('.md-code')
    const code = block?.querySelector('pre code')?.textContent ?? ''
    const language = block?.getAttribute('data-language') ?? ''
    if (button.dataset.codeAction === 'copy') {
      void navigator.clipboard?.writeText(code).then(() => {
        button.textContent = codeTools.copiedLabel
        window.setTimeout(() => { button.textContent = codeTools.copyLabel }, 1400)
      })
    }
    if (button.dataset.codeAction === 'preview') codeTools.onPreview?.(language, code)
  }
  return <div className="markdown" onClick={codeTools ? click : undefined} dangerouslySetInnerHTML={{ __html: html }} />
}

export function renderMarkdown(source: string, codeTools?: CodeTools): string {
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
  if (codeTools) {
    for (const pre of template.content.querySelectorAll('pre')) {
      const code = pre.querySelector('code')
      if (!code) continue
      const language = ([...code.classList].find((name) => name.startsWith('language-')) ?? '').slice('language-'.length).toLowerCase()
      const wrapper = document.createElement('div')
      wrapper.className = 'md-code'
      wrapper.setAttribute('data-language', language)
      const head = document.createElement('div')
      head.className = 'md-code-head'
      const label = document.createElement('span')
      label.textContent = language || 'text'
      head.append(label)
      if (codeTools.onPreview && codeTools.canPreview?.(language)) head.append(toolButton('preview', codeTools.previewLabel))
      head.append(toolButton('copy', codeTools.copyLabel))
      pre.replaceWith(wrapper)
      wrapper.append(head, pre)
    }
  }
  return template.innerHTML
}

function toolButton(action: string, text: string): HTMLButtonElement {
  const button = document.createElement('button')
  button.type = 'button'
  button.setAttribute('data-code-action', action)
  button.textContent = text
  return button
}
