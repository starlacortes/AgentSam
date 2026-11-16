import { describe, expect, it } from 'vitest'
import { createSilenceDetector, pickRecordingType } from './voice'

describe('pickRecordingType', () => {
  it('prefers WebM/Opus where the browser has it', () => {
    expect(pickRecordingType(() => true)).toBe('audio/webm;codecs=opus')
  })

  it('falls back to MP4 on Safari', () => {
    expect(pickRecordingType((t) => t === 'audio/mp4')).toBe('audio/mp4')
  })

  it('returns undefined when nothing is supported, so the browser default is used', () => {
    expect(pickRecordingType(() => false)).toBeUndefined()
  })

  it('treats a throwing check as unsupported', () => {
    expect(
      pickRecordingType((t) => {
        if (t.startsWith('audio/webm')) throw new Error('nope')
        return t === 'audio/ogg;codecs=opus'
      }),
    ).toBe('audio/ogg;codecs=opus')
  })
})

describe('createSilenceDetector', () => {
  it('never ends the recording before the user has spoken', () => {
    const done = createSilenceDetector(1000, 0.1)
    expect(done(0, 0)).toBe(false)
    expect(done(0, 5000)).toBe(false)
  })

  it('ends it once they have been quiet long enough after speaking', () => {
    const done = createSilenceDetector(1000, 0.1)
    expect(done(0.5, 0)).toBe(false)
    expect(done(0.02, 600)).toBe(false)
    expect(done(0.02, 1000)).toBe(true)
  })

  it('keeps going while they pause briefly between words', () => {
    const done = createSilenceDetector(1000, 0.1)
    done(0.5, 0)
    expect(done(0.02, 900)).toBe(false)
    expect(done(0.4, 950)).toBe(false)
    expect(done(0.02, 1900)).toBe(false)
    expect(done(0.02, 1950)).toBe(true)
  })
})
