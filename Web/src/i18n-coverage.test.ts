import { describe, expect, it } from 'vitest'
import { es } from './i18n'

// Every literal passed to t() in app code should have a Spanish entry, so the ES toggle
// never shows a stray English string. Tests are skipped: they use throwaway text.
const sources = import.meta.glob(['./**/*.{ts,tsx}', '!./**/*.test.{ts,tsx}'], { query: '?raw', import: 'default', eager: true }) as Record<string, string>

function literalKeys(source: string): string[] {
  const keys: string[] = []
  for (const match of source.matchAll(/\bt\(\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")/g)) {
    keys.push((match[1] ?? match[2] ?? '').replace(/\\'/g, "'"))
  }
  return keys
}

describe('Spanish catalog', () => {
  it('translates every string the app passes to t()', () => {
    const missing = Object.entries(sources).flatMap(([file, source]) =>
      literalKeys(source).filter((key) => !(key in es)).map((key) => `${file}: ${key}`),
    )
    expect(missing).toEqual([])
  })
})
