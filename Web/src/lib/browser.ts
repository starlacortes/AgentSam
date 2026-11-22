// Helpers for the live window onto Ada's browser.

/** The WebSocket address of the live picture, on the same origin as the app. */
export function liveBrowserURL(location: Pick<Location, 'protocol' | 'host'>): string {
  return `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/api/browser/live`
}

const ENTER = 0xff0d
const TAB = 0xff09

/**
 * The X11 key symbol for one typed character: Latin-1 characters are their own code, everything
 * else is its Unicode code point with the 0x01000000 flag. Line breaks become Enter.
 */
export function keysymFor(character: string): number | null {
  const point = character.codePointAt(0)
  if (point === undefined) return null
  if (character === '\n' || character === '\r') return ENTER
  if (character === '\t') return TAB
  if (point < 0x20 || point === 0x7f) return null
  if (point <= 0xff) return point
  return 0x01000000 + point
}

/** Types text into the remote browser one key at a time, for devices with no hardware keyboard. */
export function typeText(send: (keysym: number) => void, text: string): number {
  let sent = 0
  for (const character of text) {
    const keysym = keysymFor(character)
    if (keysym === null) continue
    send(keysym)
    sent += 1
  }
  return sent
}

export const ENTER_KEYSYM = ENTER
