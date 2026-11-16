import { describe, expect, it } from 'vitest'
import { BRIDGE_TAG, buildPreviewDocument, codePreviewDocument, isConsoleMessage, isTextFile, pickEntry, resolveLocal } from './preview'

describe('preview documents', () => {
  it('inlines local stylesheets and scripts and adds the console bridge', () => {
    const doc = buildPreviewDocument('site/index.html', {
      'site/index.html': '<html><head><link rel="stylesheet" href="styles.css"></head><body><script src="./app.js"></script></body></html>',
      'site/styles.css': 'body { color: red }',
      'site/app.js': 'console.log("</script>")',
    })
    expect(doc).toContain('body { color: red }')
    expect(doc).toContain('console.log("<\\/script>")')
    expect(doc).toContain(BRIDGE_TAG)
    expect(doc).not.toContain('href="styles.css"')
  })

  it('leaves remote and missing assets alone', () => {
    const doc = buildPreviewDocument('index.html', {
      'index.html': '<link rel="stylesheet" href="https://cdn.example.com/x.css"><script src="missing.js"></script>',
    })
    expect(doc).toContain('https://cdn.example.com/x.css')
    expect(doc).toContain('src="missing.js"')
  })

  it('refuses paths that escape the workspace', () => {
    expect(resolveLocal('index.html', '../secret.js')).toBeNull()
    expect(resolveLocal('a/index.html', '../b.css')).toBe('b.css')
    expect(resolveLocal('index.html', '/abs.css')).toBeNull()
  })

  it('picks index.html first', () => {
    expect(pickEntry(['notes.md', 'about.html', 'site/index.html', 'index.html'])).toBe('index.html')
    expect(pickEntry(['notes.md'])).toBeNull()
  })

  it('wraps fragments and svg in a full document', () => {
    expect(codePreviewDocument('html', '<p>Hi</p>')).toMatch(/^<!doctype html>.*<body><p>Hi<\/p><\/body><\/html>$/s)
    expect(codePreviewDocument('svg', '<svg></svg>')).toContain('<svg></svg>')
  })

  it('classifies readable text separately from binary downloads', () => {
    expect(isTextFile('project:README.MD')).toBe(true)
    expect(isTextFile('sources/main.swift')).toBe(true)
    expect(isTextFile('image.png')).toBe(false)
    expect(isTextFile('archive.zip')).toBe(false)
    expect(isTextFile('Makefile')).toBe(false)
  })

  it('recognizes bridge messages only', () => {
    expect(isConsoleMessage({ tag: BRIDGE_TAG, level: 'log', text: 'hi', time: 1 })).toBe(true)
    expect(isConsoleMessage({ level: 'log', text: 'hi' })).toBe(false)
  })
})
