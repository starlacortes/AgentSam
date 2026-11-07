import { useCallback, useEffect, useRef, useState } from 'react'

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
      const tick = () => {
        analyser.getByteTimeDomainData(samples)
        let peak = 0
        for (const s of samples) peak = Math.max(peak, Math.abs(s - 128))
        setLevel(Math.min(1, peak / 64))
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
export class Speaker {
  private audio: HTMLAudioElement | null = null
  private queue: Array<{ url?: string; text: string }> = []
  private playing = false
  private generation = 0
  onChange: (speaking: boolean) => void = () => undefined

  private element(): HTMLAudioElement {
    if (!this.audio) {
      this.audio = new Audio()
      this.audio.preload = 'auto'
    }
    return this.audio
  }

  /** Call from a user gesture (tap) so later playback is allowed on iOS. */
  unlock(): void {
    const audio = this.element()
    // A tiny silent WAV: playing anything inside the gesture marks the element as allowed.
    audio.src = 'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA='
    void audio.play().catch(() => undefined)
    if ('speechSynthesis' in window) window.speechSynthesis.resume()
  }

  enqueue(text: string, url?: string): void {
    this.queue.push({ text, url })
    if (!this.playing) void this.next(this.generation)
  }

  stop(): void {
    this.generation += 1
    this.queue = []
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

  private async next(generation: number): Promise<void> {
    const item = this.queue.shift()
    if (!item || generation !== this.generation) {
      if (generation === this.generation) this.setPlaying(false)
      return
    }
    this.setPlaying(true)
    let ok = false
    if (item.url) ok = await this.playURL(item.url)
    if (!ok && generation === this.generation) await speakWithBrowser(item.text)
    if (generation === this.generation) await this.next(generation)
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
      audio.play().catch(() => finish(false))
    })
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
export async function transcribe(chatID: string, audio: Blob): Promise<string> {
  const response = await fetch(`/api/chats/${chatID}/transcribe`, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': audio.type || 'audio/webm', 'X-AgentSam-Request': '1', Accept: 'application/json' },
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
