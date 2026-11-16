import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createSilenceDetector, pickRecordingType, Speaker } from './voice'

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

describe('Speaker sentence by sentence', () => {
  type Pending = { text: string; signal?: AbortSignal; resolve: () => void }
  let requests: Pending[]
  let started: number

  beforeEach(() => {
    requests = []
    started = 0
    vi.stubGlobal('fetch', vi.fn((_path: string, init: RequestInit) => new Promise<Response>((resolve, reject) => {
      const text = (JSON.parse(String(init.body)) as { text: string }).text
      init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
      requests.push({ text, signal: init.signal ?? undefined, resolve: () => resolve(new Response(new Uint8Array([1, 2, 3]), { headers: { 'Content-Type': 'audio/mpeg' } })) })
    })))
    class FakeContext {
      currentTime = 0
      destination = {}
      resume() { return Promise.resolve() }
      decodeAudioData() { return Promise.resolve({ duration: 2 }) }
      createBufferSource() {
        return { buffer: null, onended: null, connect() {}, start() { started += 1 }, stop() {} }
      }
    }
    vi.stubGlobal('AudioContext', FakeContext)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

  it('asks the voice server for one sentence at a time, in order, while the earlier ones play', async () => {
    const speaker = new Speaker('en-US')
    speaker.enqueueText('First sentence.', '/speech')
    speaker.enqueueText('Second sentence.', '/speech')
    speaker.enqueueText('Third sentence.', '/speech')
    await settle()
    expect(requests.map((r) => r.text)).toEqual(['First sentence.'])

    requests[0]!.resolve()
    await settle()
    expect(started).toBe(1)
    expect(speaker.speaking).toBe(true)
    expect(requests.map((r) => r.text)).toEqual(['First sentence.', 'Second sentence.'])

    requests[1]!.resolve()
    await settle()
    expect(started).toBe(2)
    expect(requests.map((r) => r.text)).toEqual(['First sentence.', 'Second sentence.', 'Third sentence.'])
  })

  it('cancels the sentence being made when stopped, and the next reply starts fresh', async () => {
    const speaker = new Speaker('en-US')
    speaker.enqueueText('Old reply.', '/speech')
    speaker.enqueueText('Old reply, part two.', '/speech')
    await settle()
    speaker.stop()
    expect(requests[0]!.signal?.aborted).toBe(true)

    speaker.enqueueText('New reply.', '/speech')
    await settle()
    expect(requests.map((r) => r.text)).toEqual(['Old reply.', 'New reply.'])
    requests[1]!.resolve()
    await settle()
    expect(started).toBe(1)
  })
})
