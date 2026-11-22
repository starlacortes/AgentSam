import { describe, expect, it } from 'vitest'
import { ENTER_KEYSYM, keysymFor, liveBrowserURL, typeText } from './browser'

describe('live browser helpers', () => {
  it('builds the live address on the app’s own origin', () => {
    expect(liveBrowserURL({ protocol: 'https:', host: 'ada.example.com' })).toBe('wss://ada.example.com/api/browser/live')
    expect(liveBrowserURL({ protocol: 'http:', host: 'localhost:5173' })).toBe('ws://localhost:5173/api/browser/live')
  })

  it('maps characters to key symbols', () => {
    expect(keysymFor('a')).toBe(0x61)
    expect(keysymFor('ñ')).toBe(0xf1)
    expect(keysymFor('€')).toBe(0x01000000 + 0x20ac)
    expect(keysymFor('\n')).toBe(ENTER_KEYSYM)
    expect(keysymFor('\u0007')).toBeNull()
  })

  it('types text in order and skips control characters', () => {
    const keys: number[] = []
    expect(typeText((key) => keys.push(key), 'hi\u0000 ¿')).toBe(4)
    expect(keys).toEqual([0x68, 0x69, 0x20, 0xbf])
  })
})
