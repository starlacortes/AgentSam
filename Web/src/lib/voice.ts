import { useCallback, useEffect, useRef, useState } from 'react'
import { markVoice } from './voiceTiming'

/** Recording formats browsers support, best first. Chrome and Firefox record WebM/Opus, Safari records MP4/AAC. */
const RECORDING_TYPES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus']

export function pickRecordingType(isSupported: (type: string) => boolean = (t) => MediaRecorder.isTypeSupported(t)): string | undefined {
  return RECORDING_TYPES.find((type) => {
    try {
      return isSupported(type)
    } catch {
      return false
    }
  })
}

export function canRecord(): boolean {
  return typeof window !== 'undefined' && typeof MediaRecorder !== 'undefined' && !!navigator.mediaDevices?.getUserMedia
}

/** Recordings shorter than this are almost always an accidental tap. */
export const MIN_RECORDING_MS = 400
/** Long enough for a real request, short enough to stay under the server's upload cap. */
export const MAX_RECORDING_MS = 120_000

/** Mic level (0–1) above which we count the user as speaking, in a quiet room. */
export const SPEECH_LEVEL = 0.12
/** How long the user must stay quiet, after speaking, before the recording ends on its own. */
export const SILENCE_MS = 800
/** How long Ada waits for the first words before she stops listening on her own. */
export const NO_SPEECH_MS = 8000
/** Sound has to last this long to count as talking, so a tap on the desk or a click doesn't. */
export const MIN_VOICED_MS = 120

/** How long the turn detector spends learning the room's background noise before it listens for words. */
const CALIBRATION_MS = 300
/** How far back the turn detector looks to judge the room's background level. */
const FLOOR_WINDOW_MS = 3000
/** Which share of recent frames counts as the room's background: the quieter fifth. */
const FLOOR_PERCENTILE = 0.2

/** Why a recording ended: they finished talking, never started, it was tapped off, or it hit the length cap. */
export type RecordingEnd = 'silence' | 'no-speech' | 'manual' | 'limit'

/**
 * Decides when someone has finished their turn. Returns 'listening' while they may still talk,
 * 'finished' once they have been quiet for `silenceMs` after speaking, and 'no-speech' when nothing
 * was said for `noSpeechMs`. The speech threshold rises with a noisy room's background level, so a
 * café or a fan doesn't keep the microphone open forever.
 */
export function createTurnDetector({ silenceMs = SILENCE_MS, threshold = SPEECH_LEVEL, noSpeechMs = NO_SPEECH_MS, minVoicedMs = MIN_VOICED_MS } = {}) {
  let startedAt: number | null = null
  let previous: number | null = null
  /** Recent levels, for the room's background level. */
  const recent: { at: number; level: number }[] = []
  let floor = 0
  let wasLoud = false
  /** How long the current stretch of loud frames has lasted. */
  let run = 0
  let lastVoice: number | null = null
  /** A word heard while the room was still being learned: confirmed once it goes quiet after it. */
  let early: { end: number; quietest: number } | null = null
  let earlyRun = 0
  let earlyQuietest = 1
  return (level: number, now: number): 'listening' | 'finished' | 'no-speech' => {
    if (startedAt === null) startedAt = now
    const elapsed = previous === null ? 0 : Math.max(0, now - previous)
    previous = now
    while (recent.length && now - recent[0]!.at > FLOOR_WINDOW_MS) recent.shift()
    // The background level is a low percentile of the last few seconds: not the quietest moment,
    // so a fan or a café that flickers up and down doesn't look like someone talking, and low
    // enough that the gaps between someone's words keep it under their voice.
    if (recent.length) floor = percentile(recent.map((frame) => frame.level), FLOOR_PERCENTILE)
    recent.push({ at: now, level })
    if (now - startedAt < CALIBRATION_MS) {
      // Still learning the room. A loud stretch here might be noise or an answer given the
      // moment the microphone opened; it counts as speech only if the room then goes quiet.
      const above = level >= threshold
      earlyRun = above ? earlyRun + (wasLoud ? elapsed : 0) : 0
      earlyQuietest = above ? Math.min(earlyQuietest, level) : 1
      if (earlyRun >= minVoicedMs) early = { end: now, quietest: earlyQuietest }
      wasLoud = above
    } else {
      const loud = level >= Math.max(threshold, floor + threshold * 0.8)
      // Only time between two loud frames counts, so one click after a stalled frame isn't talking.
      run = loud ? run + (wasLoud ? elapsed : 0) : 0
      wasLoud = loud
      // Once they have spoken, a shorter stretch keeps the turn going (a word after a pause).
      if (run >= (lastVoice === null ? minVoicedMs : minVoicedMs / 2)) lastVoice = now
      if (lastVoice === null && early && level < threshold && level <= early.quietest / 2) lastVoice = early.end
    }
    if (lastVoice !== null) return now - lastVoice >= silenceMs ? 'finished' : 'listening'
    return now - startedAt >= noSpeechMs ? 'no-speech' : 'listening'
  }
}

function percentile(values: number[], fraction: number): number {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))] ?? 0
}

export type RecorderState = 'idle' | 'starting' | 'recording'

/**
 * Tap to start; it ends on its own when the user stops talking (or tap again to finish). Resolves
 * the finished recording through `onDone`, with why it ended. Echo cancellation stays on as a
 * second guard, but the voice screen never records while Ada is speaking.
 */
export function useRecorder(onDone: (audio: Blob, durationMs: number, ended: RecordingEnd) => void, onError: (message: string) => void) {
  const [state, setState] = useState<RecorderState>('idle')
  // The mic level changes every frame, so it lives in a ref the orb reads, not in state:
  // state would re-render the whole voice screen sixty times a second.
  const level = useRef(0)
  const recorder = useRef<MediaRecorder | null>(null)
  const stream = useRef<MediaStream | null>(null)
  const startedAt = useRef(0)
  const limitTimer = useRef<number | null>(null)
  const meter = useRef<{ ctx: AudioContext; frame: number } | null>(null)
  const ending = useRef<RecordingEnd>('manual')
  /** Set when stop is asked for while the microphone is still being opened, so it closes as soon as it opens. */
  const cancelStart = useRef(false)
  const done = useRef(onDone)
  done.current = onDone

  const cleanup = useCallback(() => {
    if (limitTimer.current !== null) window.clearTimeout(limitTimer.current)
    limitTimer.current = null
    stream.current?.getTracks().forEach((track) => track.stop())
    stream.current = null
    if (meter.current) {
      cancelAnimationFrame(meter.current.frame)
      void meter.current.ctx.close().catch(() => undefined)
      meter.current = null
    }
    level.current = 0
  }, [])

  useEffect(() => () => {
    cancelStart.current = true
    if (recorder.current?.state === 'recording') recorder.current.stop()
    cleanup()
  }, [cleanup])

  const stop = useCallback(() => {
    if (!recorder.current) cancelStart.current = true
    if (recorder.current?.state === 'recording') {
      ending.current = 'manual'
      recorder.current.stop()
    }
  }, [])

  const start = useCallback(async () => {
    if (state !== 'idle') return
    cancelStart.current = false
    setState('starting')
    try {
      const media = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } })
      if (cancelStart.current) {
        // Stopped while the permission prompt was up (they typed instead, or closed voice mode).
        media.getTracks().forEach((track) => track.stop())
        setState('idle')
        return
      }
      stream.current = media
      const mimeType = pickRecordingType()
      const rec = new MediaRecorder(media, mimeType ? { mimeType } : undefined)
      const chunks: Blob[] = []
      rec.ondataavailable = (event) => {
        if (event.data.size > 0) chunks.push(event.data)
      }
      rec.onstop = () => {
        const duration = Date.now() - startedAt.current
        const type = rec.mimeType || mimeType || 'audio/webm'
        cleanup()
        recorder.current = null
        setState('idle')
        done.current(new Blob(chunks, { type }), duration, ending.current)
      }
      recorder.current = rec
      ending.current = 'manual'
      startedAt.current = Date.now()
      rec.start(250)
      setState('recording')
      limitTimer.current = window.setTimeout(() => {
        if (rec.state !== 'recording') return
        ending.current = 'limit'
        rec.stop()
      }, MAX_RECORDING_MS)
      startMeter(media)
    } catch (err) {
      cleanup()
      setState('idle')
      const name = err instanceof DOMException ? err.name : ''
      onError(
        name === 'NotAllowedError'
          ? 'Microphone access was blocked. Allow it in your browser’s site settings to talk to Ada.'
          : name === 'NotFoundError'
            ? 'No microphone was found.'
            : 'Couldn’t start the microphone.',
      )
    }
  }, [cleanup, onError, state])

  function startMeter(media: MediaStream) {
    try {
      const ctx = new AudioContext()
      // Made after an await, so some browsers start it suspended; a suspended meter reads silence.
      void ctx.resume().catch(() => undefined)
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 512
      ctx.createMediaStreamSource(media).connect(analyser)
      const samples = new Uint8Array(analyser.fftSize)
      const turn = createTurnDetector()
      const tick = () => {
        analyser.getByteTimeDomainData(samples)
        let peak = 0
        for (const s of samples) peak = Math.max(peak, Math.abs(s - 128))
        const current = Math.min(1, peak / 64)
        level.current = current
        // Hands-free: end the recording once they stop talking, which sends it for transcription,
        // or once nothing has been said for a while, which just closes the microphone.
        // A meter that isn't running hears only silence, so it must not end the recording.
        const state = ctx.state === 'running' ? turn(current, performance.now()) : 'listening'
        if (state !== 'listening' && recorder.current?.state === 'recording') {
          ending.current = state === 'finished' ? 'silence' : 'no-speech'
          recorder.current.stop()
          return
        }
        if (meter.current) meter.current.frame = requestAnimationFrame(tick)
      }
      meter.current = { ctx, frame: requestAnimationFrame(tick) }
    } catch {
      // The level meter is decoration; recording works without it.
    }
  }

  /** How loud the microphone is right now, 0–1. */
  const readLevel = useCallback(() => level.current, [])

  return { state, readLevel, start, stop }
}

/**
 * Plays coordinator replies one after another. Uses server speech (an MP3 URL) when it's set up,
 * and the browser's own voice otherwise. Safari only lets audio play after a tap, so `unlock()`
 * must be called from a click handler before the first reply arrives.
 */
const CHUNKED = /chunk=0\b/

interface SpeechItem {
  text: string
  /** Legacy: a GET URL for a whole stored message, played through an <audio> element. */
  url?: string
  /** Server audio for one sentence. Resolves once `begin()` has fetched it. */
  audio?: Promise<SpeechAudio | null>
  /** Starts fetching `audio`. Sentences are fetched one at a time, in order, ahead of playback. */
  begin?: () => void
}

/**
 * How many sentences may be with the voice server at once. One keeps the first sentence from
 * competing with the rest (a local Kokoro server makes them one after another anyway), and
 * each later sentence is made while the one before it plays.
 */
const MAX_SPEECH_REQUESTS = 1

/**
 * How far ahead of the listener a long reply is made. Ada reads replies in full, however long, so
 * sentences are only fetched and scheduled while less than this much audio is waiting to play.
 * That keeps memory and voice-server use flat for a reply that takes many minutes to read, and
 * means stopping doesn't waste audio for the rest of it.
 */
const MAX_AHEAD_SECONDS = 30
/** Fetched sentences waiting to be scheduled, at most (for playback without the audio graph). */
const MAX_READY_CLIPS = 3

interface SpeechAudio {
  data: ArrayBuffer
  type: string
}

type ContextConstructor = typeof AudioContext

function audioContextConstructor(): ContextConstructor | null {
  if (typeof window === 'undefined') return null
  return window.AudioContext ?? (window as unknown as { webkitAudioContext?: ContextConstructor }).webkitAudioContext ?? null
}

export class Speaker {
  private audio: HTMLAudioElement | null = null
  private context: AudioContext | null = null
  /** Taps the scheduled sentences so the voice orb can follow how loud Ada is speaking. */
  private analyser: AnalyserNode | null = null
  private samples: Uint8Array<ArrayBuffer> | null = null
  private queue: SpeechItem[] = []
  private sources = new Set<AudioBufferSourceNode>()
  private drainWaiters: Array<() => void> = []
  /** When the last scheduled sentence ends, in AudioContext time. The next one is scheduled to begin exactly then. */
  private cursor = 0
  private pumping = false
  private playing = false
  private generation = 0
  /** Sentences waiting for their turn with the voice server, oldest first. */
  private unfetched: SpeechItem[] = []
  private requests = 0
  /** Sentences whose audio has arrived but that haven't been scheduled yet. */
  private ready = 0
  private aborter = new AbortController()
  onChange: (speaking: boolean) => void = () => undefined

  constructor(private language?: string) {}

  private element(): HTMLAudioElement {
    if (!this.audio) {
      this.audio = new Audio()
      this.audio.preload = 'auto'
    }
    return this.audio
  }

  private audioContext(): AudioContext | null {
    if (!this.context) {
      const Constructor = audioContextConstructor()
      if (!Constructor) return null
      try {
        this.context = new Constructor()
      } catch {
        return null
      }
    }
    return this.context
  }

  /** Where scheduled sentences play: through the level meter when it can be made, else straight out. */
  private output(context: AudioContext): AudioNode {
    if (!this.analyser) {
      try {
        const analyser = context.createAnalyser()
        analyser.fftSize = 512
        analyser.connect(context.destination)
        this.analyser = analyser
      } catch {
        return context.destination
      }
    }
    return this.analyser
  }

  /**
   * How loud the sentence playing right now is, from 0 to 1. It is 0 when nothing is playing
   * through the audio graph (the browser's own voice and <audio> playback can't be measured).
   */
  level(): number {
    const analyser = this.analyser
    if (!analyser || this.sources.size === 0) return 0
    if (!this.samples || this.samples.length !== analyser.fftSize) this.samples = new Uint8Array(analyser.fftSize)
    analyser.getByteTimeDomainData(this.samples)
    let peak = 0
    for (const sample of this.samples) peak = Math.max(peak, Math.abs(sample - 128))
    return Math.min(1, peak / 64)
  }

  /** Call from a user gesture (tap) so later playback is allowed on iOS. */
  unlock(): void {
    const audio = this.element()
    // A tiny silent WAV: playing anything inside the gesture marks the element as allowed.
    audio.src = 'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA='
    void audio.play()?.catch(() => undefined)
    void this.audioContext()?.resume().catch(() => undefined)
    if ('speechSynthesis' in window) window.speechSynthesis.resume?.()
  }

  enqueue(text: string, url?: string): void {
    this.push({ text, url })
  }

  /**
   * Speaks one sentence of a reply that is still being written. The audio starts being made
   * immediately and is scheduled back to back with the previous sentence, so there is no gap.
   * `postURL` is the server's text-to-speech endpoint; without it the browser voice reads the text.
   */
  enqueueText(text: string, postURL?: string): void {
    if (!postURL) return this.push({ text })
    const item: SpeechItem = { text }
    item.audio = new Promise((resolve) => {
      item.begin = () => {
        item.begin = undefined
        const generation = this.generation
        this.requests += 1
        // Counted before the clip is handed over, so the pump's count down always comes after it.
        // A clip from a reply that was stopped is not counted.
        const arrived = (clip: SpeechAudio | null) => {
          if (generation === this.generation) this.ready += 1
          resolve(clip)
        }
        void fetchSpeech(postURL, text, this.aborter.signal).then(arrived, () => arrived(null)).finally(() => {
          this.requests -= 1
          this.fetchAhead()
        })
      }
    })
    this.unfetched.push(item)
    this.fetchAhead()
    this.push(item)
  }

  /** Starts the next sentences' audio, oldest first, while keeping the voice server to a few requests. */
  private fetchAhead(): void {
    // Behind a single clip longer than the limit, the next sentence may still be made, so there is no gap after it.
    const roomAhead = () => this.secondsAhead() < MAX_AHEAD_SECONDS || (this.sources.size <= 1 && this.ready + this.requests === 0)
    while (this.requests < MAX_SPEECH_REQUESTS && this.unfetched.length > 0 && this.ready < MAX_READY_CLIPS && roomAhead()) {
      this.unfetched.shift()?.begin?.()
    }
  }

  /** Seconds of scheduled audio still to play. */
  private secondsAhead(): number {
    if (!this.context || this.sources.size === 0) return 0
    return Math.max(0, this.cursor - this.context.currentTime)
  }

  private push(item: SpeechItem): void {
    this.queue.push(item)
    if (!this.pumping) void this.pump()
  }

  stop(): void {
    this.generation += 1
    this.queue = []
    this.unfetched = []
    this.ready = 0
    this.aborter.abort()
    this.aborter = new AbortController()
    this.pumping = false
    for (const source of this.sources) {
      source.onended = null
      try { source.stop() } catch { /* already finished */ }
    }
    this.sources.clear()
    this.cursor = 0
    this.releaseDrain()
    this.audio?.pause()
    if ('speechSynthesis' in window) window.speechSynthesis.cancel()
    this.setPlaying(false)
  }

  get speaking(): boolean {
    return this.playing
  }

  private setPlaying(value: boolean) {
    if (this.playing !== value) {
      this.playing = value
      this.onChange(value)
    }
  }

  private releaseDrain() {
    const waiters = this.drainWaiters
    this.drainWaiters = []
    for (const resolve of waiters) resolve()
  }

  /** Resolves once everything scheduled so far has finished playing. */
  private drained(): Promise<void> {
    return this.sources.size === 0 ? Promise.resolve() : new Promise((resolve) => this.drainWaiters.push(resolve))
  }

  private async pump(): Promise<void> {
    const generation = this.generation
    this.pumping = true
    while (generation === this.generation) {
      const item = this.queue.shift()
      if (!item) break
      this.setPlaying(true)
      if (item.audio) {
        const clip = await item.audio
        if (generation !== this.generation) return
        this.ready = Math.max(0, this.ready - 1)
        if (!clip || !(await this.schedule(clip, generation))) await this.fallBack(item.text, generation)
        this.fetchAhead()
      } else {
        await this.drained()
        if (generation !== this.generation) return
        let ok = false
        if (item.url) ok = await (CHUNKED.test(item.url) ? this.playChunked(item.url, generation) : this.playURL(item.url))
        if (!ok && generation === this.generation) await speakWithBrowser(item.text, this.language)
      }
    }
    if (generation !== this.generation) return
    this.pumping = false
    if (this.sources.size === 0) this.setPlaying(false)
  }

  private async fallBack(text: string, generation: number): Promise<void> {
    await this.drained()
    if (generation === this.generation) await speakWithBrowser(text, this.language)
  }

  /** Decodes one sentence and queues it to start the instant the previous one ends. False means it couldn't be played. */
  private async schedule(clip: SpeechAudio, generation: number): Promise<boolean> {
    const context = this.audioContext()
    if (!context) return this.playBlob(clip, generation)
    try {
      const buffer = await context.decodeAudioData(clip.data)
      if (generation !== this.generation) return true
      const source = context.createBufferSource()
      source.buffer = buffer
      source.connect(this.output(context))
      const startAt = Math.max(context.currentTime + 0.02, this.cursor)
      this.cursor = startAt + buffer.duration
      this.sources.add(source)
      source.onended = () => {
        this.sources.delete(source)
        // Time has passed, so there may be room to make the next sentences of a long reply.
        this.fetchAhead()
        if (this.sources.size > 0) return
        this.releaseDrain()
        if (!this.pumping) this.setPlaying(false)
      }
      source.start(startAt)
      markVoice('playback-start')
      return true
    } catch {
      return this.playBlob(clip, generation)
    }
  }

  private async playBlob(clip: SpeechAudio, generation: number): Promise<boolean> {
    await this.drained()
    if (generation !== this.generation) return true
    const url = URL.createObjectURL(new Blob([clip.data], { type: clip.type }))
    markVoice('playback-start')
    const ok = await this.playURL(url)
    URL.revokeObjectURL(url)
    return ok
  }

  /**
   * Speech URLs ending in `chunk=0` are spoken piece by piece: the first short piece starts playing
   * while the next two are made. False means the very first piece failed, so the caller
   * can fall back to the browser voice.
   */
  private async playChunked(first: string, generation: number): Promise<boolean> {
    const fetchChunk = async (index: number): Promise<{ url: string; total: number } | null> => {
      const response = await fetch(first.replace(CHUNKED, `chunk=${index}`), { credentials: 'same-origin' })
      if (!response.ok) throw new Error(`speech ${response.status}`)
      if (response.status === 204) return null
      const total = Number(response.headers.get('X-Speech-Chunks')) || 1
      return { url: URL.createObjectURL(await response.blob()), total }
    }
    let head: { url: string; total: number } | null
    try {
      head = await fetchChunk(0)
    } catch {
      return false
    }
    if (!head) return true
    const pending = new Map<number, Promise<{ url: string; total: number } | null>>([[0, Promise.resolve(head)]])
    const ahead = (index: number) => {
      if (head && index < head.total && !pending.has(index)) pending.set(index, fetchChunk(index).catch(() => null))
    }
    const discard = () => {
      for (const rest of pending.values()) void rest.then((value) => value && URL.revokeObjectURL(value.url))
      pending.clear()
    }
    for (let index = 0; index < head.total; index += 1) {
      // Keep at most two pieces being made ahead of the one playing, so they don't all fight for the voice server.
      ahead(index + 1)
      ahead(index + 2)
      const chunk = await pending.get(index)
      pending.delete(index)
      if (generation !== this.generation) {
        if (chunk) URL.revokeObjectURL(chunk.url)
        discard()
        return true
      }
      if (!chunk) continue
      markVoice('playback-start')
      await this.playURL(chunk.url)
      URL.revokeObjectURL(chunk.url)
    }
    return true
  }

  private playURL(url: string): Promise<boolean> {
    const audio = this.element()
    return new Promise((resolve) => {
      const finish = (ok: boolean) => {
        audio.onended = null
        audio.onerror = null
        audio.onpause = null
        resolve(ok)
      }
      audio.onended = () => finish(true)
      audio.onerror = () => finish(false)
      audio.onpause = () => audio.ended || finish(true)
      audio.src = url
      void (audio.play() ?? Promise.resolve()).catch(() => finish(false))
    })
  }
}

/** Asks the server to speak `text`; null means it couldn't, so the caller can use the browser voice. */
async function fetchSpeech(path: string, text: string, signal?: AbortSignal): Promise<SpeechAudio | null> {
  try {
    const response = await fetch(path, {
      method: 'POST',
      signal,
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-AgentSam-Request': '1' },
      body: JSON.stringify({ text }),
    })
    if (!response.ok) return null
    markVoice('tts-first-byte')
    return { data: await response.arrayBuffer(), type: response.headers.get('Content-Type') ?? 'audio/mpeg' }
  } catch {
    return null
  }
}

/** The browser's built-in voice, used when the server has no text-to-speech provider. */
/**
 * Splits text for the browser's voice into pieces of at most `limit` characters, at sentence ends
 * where possible, then at commas or spaces. Some browsers (Chrome on desktop in particular) go
 * silent partway through one long utterance, so a long reply is read as many short ones.
 */
export function browserSpeechPieces(text: string, limit = 220): string[] {
  const sentences = text.replace(/\s+/g, ' ').trim().match(/.+?(?:[.!?]+(?=\s|$)|$)/g) ?? []
  const pieces: string[] = []
  let buffer = ''
  const flush = () => { if (buffer.trim()) pieces.push(buffer.trim()); buffer = '' }
  for (let sentence of sentences) {
    sentence = sentence.trim()
    if (!sentence) continue
    // A sentence longer than the limit is broken at its last comma, else its last space, before the limit.
    while (sentence.length > limit) {
      const head = sentence.slice(0, limit)
      const comma = head.lastIndexOf(', ')
      const space = head.lastIndexOf(' ')
      const cut = comma > limit / 3 ? comma + 1 : space > 0 ? space : limit
      flush()
      pieces.push(sentence.slice(0, cut).trim())
      sentence = sentence.slice(cut).trim()
    }
    if (buffer && buffer.length + 1 + sentence.length > limit) flush()
    buffer = buffer ? `${buffer} ${sentence}` : sentence
  }
  flush()
  return pieces
}

export function speakWithBrowser(text: string, lang = navigator.language): Promise<void> {
  return new Promise((resolve) => {
    if (!('speechSynthesis' in window)) return resolve()
    const pieces = browserSpeechPieces(text)
    if (pieces.length === 0) return resolve()
    // All pieces are queued at once, so the browser reads them back to back. Stopping cancels the
    // whole queue, which ends the pieces with a 'canceled' or 'interrupted' error. Any other error
    // on one piece skips just that piece; the rest keep reading.
    pieces.forEach((piece, index) => {
      const last = index === pieces.length - 1
      const utterance = new SpeechSynthesisUtterance(piece)
      utterance.lang = lang
      utterance.rate = 1.05
      if (last) utterance.onend = () => resolve()
      utterance.onerror = (event?: SpeechSynthesisErrorEvent) => {
        const stopped = event?.error === 'canceled' || event?.error === 'interrupted'
        if (last || stopped || !event) resolve()
      }
      window.speechSynthesis.speak(utterance)
    })
  })
}

/** Sends a recording to the server and returns what was said. */
async function postRecording(path: string, audio: Blob, language?: string): Promise<string> {
  const response = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': audio.type || 'audio/webm', 'X-AgentSam-Request': '1', Accept: 'application/json', ...(language ? { 'Accept-Language': language } : {}) },
    body: audio,
  })
  if (!response.ok) {
    let reason = `Transcription failed (${response.status})`
    try {
      const data = (await response.json()) as { reason?: string }
      if (data.reason) reason = data.reason
    } catch {
      // keep the status text
    }
    throw new Error(reason)
  }
  const data = (await response.json()) as { text: string }
  return data.text
}

export function transcribeConversation(conversationID: string, audio: Blob, language?: string): Promise<string> {
  return postRecording(`/api/conversations/${conversationID}/transcribe`, audio, language)
}
