import { describe, expect, it } from 'vitest'
import { pickRecordingType } from './voice'

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
