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
