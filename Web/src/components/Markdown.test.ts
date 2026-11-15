import { describe, expect, it } from 'vitest'
import { renderMarkdown } from './Markdown'

describe('renderMarkdown', () => {
  it('strips scripts and event handlers from agent output', () => {
    const html = renderMarkdown('# Hi\n\n<script>alert(1)</script><a href="javascript:alert(1)" onclick="x()">x</a><img src=x onerror=alert(1)>')
    expect(html).toContain('<h1>Hi</h1>')
    expect(html).not.toContain('<script')
    expect(html).not.toContain('onclick')
    expect(html).not.toContain('javascript:')
    expect(html).not.toContain('onerror')
  })

  it('opens links safely', () => {
    expect(renderMarkdown('[x](https://example.com)')).toContain('rel="noopener noreferrer"')
  })
})

describe('code tools', () => {
  const tools = { copyLabel: 'Copy', copiedLabel: 'Copied', previewLabel: 'Preview', onPreview: () => {}, canPreview: (lang: string) => lang === 'html' }

  it('adds a label and buttons to fenced code without trusting its contents', () => {
    const html = renderMarkdown('```html\n<button onclick="x()">Hi</button>\n```\n\n```js\nlet a = 1\n```', tools)
    expect(html).toContain('data-language="html"')
    expect(html).toContain('data-code-action="preview"')
    expect(html.match(/data-code-action="preview"/g)).toHaveLength(1)
    expect(html.match(/data-code-action="copy"/g)).toHaveLength(2)
    expect(html).toContain('&lt;button onclick')
  })

  it('leaves plain rendering unchanged without tools', () => {
    expect(renderMarkdown('```html\n<p>x</p>\n```')).not.toContain('md-code')
  })
})
