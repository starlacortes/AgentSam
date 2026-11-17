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

/** Mic level (0–1) above which we count the user as speaking. */
export const SPEECH_LEVEL = 0.12
/** How long the user must stay quiet, after speaking, before the recording ends on its own. */
export const SILENCE_MS = 800

/**
 * Decides when someone has stopped talking: quiet for `silenceMs` after they were heard.
 * Silence before the first words never ends the recording.
 */
export function createSilenceDetector(silenceMs = SILENCE_MS, threshold = SPEECH_LEVEL) {
  let lastVoice: number | null = null
  return (level: number, now: number): boolean => {
    if (level >= threshold) lastVoice = now
    return lastVoice !== null && now - lastVoice >= silenceMs
  }
}

export type RecorderState = 'idle' | 'starting' | 'recording'

/**
 * Tap to start, tap again to finish. Resolves the finished recording through `onDone`.
 * Echo cancellation stays on so a reply playing from the speakers isn't picked up.
 */
export function useRecorder(onDone: (audio: Blob, durationMs: number) => void, onError: (message: string) => void) {
  const [state, setState] = useState<RecorderState>('idle')
  const [level, setLevel] = useState(0)
  const recorder = useRef<MediaRecorder | null>(null)
  const stream = useRef<MediaStream | null>(null)
  const startedAt = useRef(0)
  const limitTimer = useRef<number | null>(null)
  const meter = useRef<{ ctx: AudioContext; frame: number } | null>(null)
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
    setLevel(0)
  }, [])

  useEffect(() => () => {
    if (recorder.current?.state === 'recording') recorder.current.stop()
    cleanup()
  }, [cleanup])

  const stop = useCallback(() => {
    if (recorder.current?.state === 'recording') recorder.current.stop()
  }, [])

  const start = useCallback(async () => {
    if (state !== 'idle') return
    setState('starting')
    try {
      const media = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } })
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
        done.current(new Blob(chunks, { type }), duration)
      }
      recorder.current = rec
      startedAt.current = Date.now()
      rec.start(250)
      setState('recording')
      limitTimer.current = window.setTimeout(() => rec.state === 'recording' && rec.stop(), MAX_RECORDING_MS)
      startMeter(media)
    } catch (err) {
      cleanup()
      setState('idle')
      const name = err instanceof DOMException ? err.name : ''
      onError(
        name === 'NotAllowedError'
          ? 'Microphone access was blocked. Allow it in your browser’s site settings to talk to your coordinator.'
          : name === 'NotFoundError'
            ? 'No microphone was found.'
            : 'Couldn’t start the microphone.',
      )
    }
  }, [cleanup, onError, state])

  function startMeter(media: MediaStream) {
    try {
      const ctx = new AudioContext()
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 512
      ctx.createMediaStreamSource(media).connect(analyser)
      const samples = new Uint8Array(analyser.fftSize)
      const finishedTalking = createSilenceDetector()
      const tick = () => {
        analyser.getByteTimeDomainData(samples)
        let peak = 0
        for (const s of samples) peak = Math.max(peak, Math.abs(s - 128))
        const level = Math.min(1, peak / 64)
        setLevel(level)
        // Hands-free: end the recording once they stop talking, which sends it for transcription.
        if (finishedTalking(level, performance.now()) && recorder.current?.state === 'recording') {
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

  return { state, level, start, stop }
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
    if ('speechSynthesis' in window) window.speechSynthesis.resume()
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
        this.requests += 1
        void fetchSpeech(postURL, text, this.aborter.signal).then(resolve, () => resolve(null)).finally(() => {
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
    while (this.requests < MAX_SPEECH_REQUESTS && this.unfetched.length > 0) this.unfetched.shift()?.begin?.()
  }

  private push(item: SpeechItem): void {
    this.queue.push(item)
    if (!this.pumping) void this.pump()
  }

  stop(): void {
    this.generation += 1
    this.queue = []
    this.unfetched = []
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
        if (!clip || !(await this.schedule(clip, generation))) await this.fallBack(item.text, generation)
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
export function speakWithBrowser(text: string, lang = navigator.language): Promise<void> {
  return new Promise((resolve) => {
    if (!('speechSynthesis' in window)) return resolve()
    const utterance = new SpeechSynthesisUtterance(text)
    utterance.lang = lang
    utterance.rate = 1.05
    utterance.onend = () => resolve()
    utterance.onerror = () => resolve()
    window.speechSynthesis.speak(utterance)
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

export function transcribe(chatID: string, audio: Blob): Promise<string> {
  return postRecording(`/api/chats/${chatID}/transcribe`, audio)
}

export function transcribeConversation(conversationID: string, audio: Blob, language?: string): Promise<string> {
  return postRecording(`/api/conversations/${conversationID}/transcribe`, audio, language)
}
