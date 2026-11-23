import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createTurnDetector, pickRecordingType, Speaker } from './voice'

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

describe('createTurnDetector', () => {
  type Detect = ReturnType<typeof createTurnDetector>
  /** Feeds frames 20 ms apart; `level` may vary with time. Returns the last answer. */
  const frames = (detect: Detect, level: number | ((now: number) => number), from: number, to: number) => {
    let last: ReturnType<Detect> = 'listening'
    for (let now = from; now <= to; now += 20) last = detect(typeof level === 'number' ? level : level(now), now)
    return last
  }

  /** Talking: loud syllables with short dips between them, like real speech. */
  const talking = (peak: number) => (now: number) => (now % 200 < 140 ? peak : peak * 0.3)

  it('keeps listening through quiet before the first words, then gives up', () => {
    const detect = createTurnDetector({ silenceMs: 1000, threshold: 0.1, noSpeechMs: 5000 })
    expect(frames(detect, 0.01, 0, 4900)).toBe('listening')
    expect(frames(detect, 0.01, 4920, 5000)).toBe('no-speech')
  })

  it('finishes once they have been quiet long enough after speaking', () => {
    const detect = createTurnDetector({ silenceMs: 1000, threshold: 0.1 })
    expect(frames(detect, 0.01, 0, 300)).toBe('listening')
    expect(frames(detect, talking(0.5), 320, 700)).toBe('listening')
    expect(frames(detect, 0.02, 720, 1500)).toBe('listening')
    expect(frames(detect, 0.02, 1520, 1760)).toBe('finished')
  })

  it('hears a quick answer said the moment the microphone opens', () => {
    const detect = createTurnDetector({ silenceMs: 800, threshold: 0.12 })
    expect(frames(detect, 0.5, 0, 260)).toBe('listening')
    expect(frames(detect, 0.01, 280, 1000)).toBe('listening')
    expect(frames(detect, 0.01, 1020, 1200)).toBe('finished')
  })

  it('keeps going while they pause briefly between words', () => {
    const detect = createTurnDetector({ silenceMs: 1000, threshold: 0.1 })
    frames(detect, 0.01, 0, 300)
    frames(detect, talking(0.5), 320, 700)
    expect(frames(detect, 0.02, 720, 1500)).toBe('listening')
    expect(frames(detect, talking(0.4), 1520, 1900)).toBe('listening')
    expect(frames(detect, 0.02, 1920, 2800)).toBe('listening')
    expect(frames(detect, 0.02, 2820, 3000)).toBe('finished')
  })

  it('ignores a click too short to be talking, even after a stalled frame', () => {
    const detect = createTurnDetector({ silenceMs: 1000, threshold: 0.1, noSpeechMs: 3000 })
    frames(detect, 0.01, 0, 1000)
    frames(detect, 0.9, 1020, 1060)
    expect(detect(0.01, 1080)).toBe('listening')
    // A frame arrives late (the tab was busy), and it happens to be loud.
    expect(detect(0.9, 1500)).toBe('listening')
    expect(frames(detect, 0.01, 1520, 2980)).toBe('listening')
    expect(frames(detect, 0.01, 3000, 3100)).toBe('no-speech')
  })

  it('hears someone over a steady noisy room, and notices when they stop', () => {
    const detect = createTurnDetector({ silenceMs: 800, threshold: 0.12 })
    expect(frames(detect, 0.18, 0, 1000)).toBe('listening')
    expect(frames(detect, talking(0.6), 1020, 2000)).toBe('listening')
    expect(frames(detect, 0.18, 2020, 2700)).toBe('listening')
    expect(frames(detect, 0.18, 2720, 2900)).toBe('finished')
  })

  it('never cuts off a long answer, even one that starts the moment the microphone opens', () => {
    const detect = createTurnDetector({ silenceMs: 800, threshold: 0.12 })
    expect(frames(detect, talking(0.5), 0, 6000)).toBe('listening')
    expect(frames(detect, 0.01, 6020, 6700)).toBe('listening')
    expect(frames(detect, 0.01, 6720, 6900)).toBe('finished')
  })

  it('ends the turn soon after they stop, in random café noise', () => {
    let seed = 7
    const random = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648
    const noise = () => 0.1 + 0.16 * random()
    for (let trial = 0; trial < 20; trial += 1) {
      const detect = createTurnDetector({ silenceMs: 800, threshold: 0.12, noSpeechMs: 60_000 })
      expect(frames(detect, noise, 0, 2000)).toBe('listening')
      expect(frames(detect, talking(0.7), 2020, 4000)).toBe('listening')
      let ended = 0
      for (let now = 4020; now < 10_000 && !ended; now += 20) if (detect(noise(), now) === 'finished') ended = now
      expect(ended).toBeGreaterThan(4500)
      expect(ended).toBeLessThan(6000)
    }
  })

  it('isn’t fooled by noise that flickers up and down', () => {
    const detect = createTurnDetector({ silenceMs: 800, threshold: 0.12, noSpeechMs: 6000 })
    // A fan or a café: peaks swinging between 0.10 and 0.26 every frame.
    const noise = (now: number) => 0.1 + 0.16 * Math.abs(Math.sin(now * 1.7))
    expect(frames(detect, noise, 0, 1500)).toBe('listening')
    expect(frames(detect, talking(0.6), 1520, 3000)).toBe('listening')
    expect(frames(detect, noise, 3020, 3700)).toBe('listening')
    expect(frames(detect, noise, 3720, 3900)).toBe('finished')
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
