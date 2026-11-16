/**
 * Stage timing for one voice turn, so "it feels slow" can be pinned on a stage.
 * A turn starts at `speech-end`; every later mark records milliseconds since then (first mark of each name wins).
 * Read the latest turn from the console (`voice timing`) or `window.__voiceTimings`.
 */
export type VoiceStage = 'speech-end' | 'stt-done' | 'reply-first-text' | 'first-sentence' | 'tts-first-byte' | 'playback-start' | 'reply-complete'

let started = 0
let marks: Partial<Record<VoiceStage, number>> = {}

export function markVoice(stage: VoiceStage, now: number = performance.now()): void {
  if (stage === 'speech-end') {
    started = now
    marks = {}
  } else if (!started || marks[stage] !== undefined) {
    return
  }
  marks[stage] = Math.round(now - started)
  if (typeof window !== 'undefined') (window as unknown as { __voiceTimings?: unknown }).__voiceTimings = { ...marks }
  if (stage === 'playback-start') console.info('voice timing (ms since you stopped talking)', { ...marks })
}

export function voiceTimings(): Partial<Record<VoiceStage, number>> {
  return { ...marks }
}
