import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useI18n } from '../../i18n'
import { api } from '../../api/client'
import type { VoiceInfo } from '../../api/chatTypes'
import { SPOKEN_LIMIT, takeSpeakable } from '../../lib/coordinator'
import { markVoice } from '../../lib/voiceTiming'
import { canRecord, MIN_RECORDING_MS, Speaker, useRecorder } from '../../lib/voice'
import { Icon } from './Icon'
import { useDialogA11y } from './Overlay'

interface SpeechResult {
  isFinal: boolean
  0: { transcript: string }
}

interface SpeechResultEvent {
  results: ArrayLike<SpeechResult>
}

interface Recognition {
  continuous: boolean
  interimResults: boolean
  lang: string
  onresult: ((event: SpeechResultEvent) => void) | null
  onerror: ((event: { error?: string }) => void) | null
  onend: (() => void) | null
  start: () => void
  stop: () => void
  abort: () => void
}

type RecognitionConstructor = new () => Recognition

function speechRecognition(): RecognitionConstructor | null {
  const scope = window as unknown as { SpeechRecognition?: RecognitionConstructor; webkitSpeechRecognition?: RecognitionConstructor }
  return scope.SpeechRecognition ?? scope.webkitSpeechRecognition ?? null
}

export interface VoiceReply {
  text: string
  speechURL?: string
}

/** What Ada has written so far, passed along while she is still writing so speech can start early. */
export interface VoicePartial {
  text: string
  /** The part of the reply meant to be heard, once Ada has moved on to on-screen detail. */
  speech?: string
  final: boolean
  /** Where to POST a sentence to have the server speak it. */
  speechPath: string
}

function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

/**
 * Feeds how loud Ada is speaking into the orb's `--level` while she speaks, smoothed so the orb
 * swells with her voice instead of flickering. Writes the style directly to skip re-renders.
 */
function useSpeakingLevel(orb: { current: HTMLElement | null }, speaker: { current: Speaker | null }, speaking: boolean) {
  useEffect(() => {
    const element = orb.current
    if (!speaking || !element || prefersReducedMotion() || typeof window.requestAnimationFrame !== 'function') return
    let smoothed = 0
    let frame = 0
    const tick = () => {
      const level = speaker.current?.level() ?? 0
      smoothed += (level - smoothed) * (level > smoothed ? 0.45 : 0.12)
      element.style.setProperty('--level', smoothed.toFixed(3))
      element.toggleAttribute('data-metered', level > 0 || smoothed > 0.01)
      frame = window.requestAnimationFrame(tick)
    }
    frame = window.requestAnimationFrame(tick)
    return () => {
      window.cancelAnimationFrame(frame)
      element.style.removeProperty('--level')
      element.removeAttribute('data-metered')
    }
  }, [orb, speaker, speaking])
}

export function VoiceMode({ onSend, onTranscribe, onClose, activity = null }: { onSend: (text: string, waitForCompletion: boolean, onPartial?: (update: VoicePartial) => void) => Promise<VoiceReply | null>; onTranscribe: (audio: Blob) => Promise<string>; onClose: () => void; /** What Ada is doing right now, such as "Searching Gmail"; null while she isn't working. */ activity?: string | null }) {
  const { t, lang } = useI18n()
  const [phase, setPhase] = useState<'idle' | 'listening' | 'thinking' | 'speaking'>('idle')
  const [transcript, setTranscript] = useState('')
  const [response, setResponse] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [muted, setMuted] = useState(false)
  const [voiceInfo, setVoiceInfo] = useState<VoiceInfo | null>(null)
  const [browserRecognition] = useState(() => speechRecognition() !== null)
  const serverListening = Boolean(voiceInfo?.setup.stt && canRecord())
  const supported = serverListening || browserRecognition
  const speechOutput = Boolean(voiceInfo?.setup.tts) || 'speechSynthesis' in window
  const root = useRef<HTMLDivElement>(null)
  const orb = useRef<HTMLButtonElement>(null)
  const recognition = useRef<Recognition | null>(null)
  const speaker = useRef<Speaker | null>(null)
  const heard = useRef('')
  const submitOnEnd = useRef(false)
  const sending = useRef(false)
  const mute = useRef(false)
  const active = useRef(true)
  const submission = useRef<(text: string) => Promise<void>>(async () => {})
  if (!speaker.current) {
    speaker.current = new Speaker(lang === 'es' ? 'es-ES' : 'en-US')
    speaker.current.onChange = (speaking) => {
      if (active.current) setPhase(speaking ? 'speaking' : sending.current ? 'thinking' : 'idle')
    }
  }
  const recorder = useRecorder((audio, duration) => {
    if (!active.current || !submitOnEnd.current) return
    submitOnEnd.current = false
    if (duration < MIN_RECORDING_MS || audio.size === 0) {
      setPhase('idle')
      return
    }
    setPhase('thinking')
    markVoice('speech-end')
    void onTranscribe(audio).then((text) => {
      if (!active.current) return
      markVoice('stt-done')
      if (text.trim()) {
        setTranscript(text)
        void submission.current(text)
      } else {
        setPhase('idle')
        setError(t('I couldn’t hear that. Check microphone access, or type your message instead.'))
      }
    }).catch((reason: unknown) => {
      if (!active.current) return
      setPhase('idle')
      setError(reason instanceof Error ? reason.message : t('I couldn’t hear that. Check microphone access, or type your message instead.'))
    })
  }, (message) => {
    setPhase('idle')
    setError(t(message))
  })

  const stopListening = (discard: boolean) => {
    submitOnEnd.current = !discard
    recorder.stop()
    const current = recognition.current
    recognition.current = null
    if (!current) {
      heard.current = ''
      setTranscript('')
      setPhase((value) => value === 'listening' ? 'idle' : value)
      return
    }
    current.onend = null
    current.onresult = null
    current.onerror = null
    current.abort()
    heard.current = ''
    setTranscript('')
    setPhase((value) => value === 'listening' ? 'idle' : value)
  }

  const stopSpeaking = () => {
    speaker.current?.stop()
    setPhase((value) => value === 'speaking' ? 'idle' : value)
  }

  const close = () => {
    stopListening(true)
    stopSpeaking()
    onClose()
  }
  useDialogA11y(root, close)

  useEffect(() => {
    active.current = true
    void api<VoiceInfo>('voice').then((info) => {
      if (active.current) setVoiceInfo(info)
    }).catch(() => undefined)
    return () => {
      active.current = false
      submitOnEnd.current = false
      const current = recognition.current
      recognition.current = null
      if (current) {
        current.onend = null
        current.onresult = null
        current.onerror = null
        current.abort()
      }
      speaker.current?.stop()
    }
  }, [])

  /** Speaks each finished sentence as Ada writes it, instead of waiting for the whole reply. */
  const streamSpeech = () => {
    let from = 0
    let previous = ''
    let spoke = false
    let spokenLength = 0
    let capped = false
    return ({ text, speech, final, speechPath }: VoicePartial) => {
      if (!active.current) return
      setResponse(text)
      if (text) markVoice('reply-first-text')
      if (final) markVoice('reply-complete')
      if (mute.current || !speechOutput || capped) return
      // Once the spoken part is known, the rest of the reply is on-screen detail and is not read.
      const source = speech ?? text
      const done = final || speech !== undefined
      // Text Ada wrote before using a tool is replaced by the real answer. Start again from its top,
      // or the opening of the answer would be skipped.
      if (startedOver(previous, source)) from = 0
      previous = source
      for (let next = takeSpeakable(source, from, done); next; next = takeSpeakable(source, from, done)) {
        from = next.end
        if (!next.text) continue
        if (spoke && spokenLength + next.text.length > SPOKEN_LIMIT) {
          capped = true
          speaker.current?.enqueueText(t('The rest is on screen.'))
          return
        }
        spoke = true
        spokenLength += next.text.length
        markVoice('first-sentence')
        speaker.current?.enqueueText(next.text, voiceInfo?.setup.tts ? speechPath : undefined)
      }
      if (final && !spoke) speaker.current?.enqueueText(t('Your response is ready in the chat.'))
    }
  }

  const submit = async (raw: string) => {
    const text = raw.trim()
    if (!text || sending.current) return
    stopListening(true)
    stopSpeaking()
    sending.current = true
    setTranscript('')
    setResponse('')
    setError(null)
    setPhase('thinking')
    try {
      const answer = await onSend(text, true, streamSpeech())
      if (!active.current) return
      if (!answer?.text.trim()) {
        setPhase('idle')
        setError(t('Ada couldn’t complete that response. Return to chat for details, or try again.'))
        return
      }
      setResponse(answer.text)
      if (!speaker.current?.speaking) setPhase('idle')
    } catch {
      if (active.current) {
        setPhase('idle')
        setError(t('Ada couldn’t complete that response. Return to chat for details, or try again.'))
      }
    } finally {
      sending.current = false
    }
  }
  submission.current = submit

  const listen = () => {
    if (phase === 'listening') {
      if (serverListening) recorder.stop()
      else recognition.current?.stop()
      return
    }
    if (sending.current) return
    stopSpeaking()
    speaker.current?.unlock()
    setError(null)
    setResponse('')
    setTranscript('')
    if (serverListening) {
      submitOnEnd.current = true
      setPhase('listening')
      void recorder.start()
      return
    }
    const Constructor = speechRecognition()
    if (!Constructor) {
      setError(t('Voice recognition isn’t available in this browser. You can still type to Ada here.'))
      return
    }
    heard.current = ''
    submitOnEnd.current = true
    const next = new Constructor()
    next.continuous = false
    next.interimResults = true
    next.lang = lang === 'es' ? 'es-ES' : 'en-US'
    next.onresult = (event) => {
      const text = Array.from({ length: event.results.length }, (_, index) => event.results[index]?.[0].transcript ?? '').join(' ').trim()
      heard.current = text
      setTranscript(text)
    }
    next.onerror = () => {
      submitOnEnd.current = false
      if (active.current) {
        setPhase('idle')
        setError(t('I couldn’t hear that. Check microphone access, or type your message instead.'))
      }
    }
    next.onend = () => {
      recognition.current = null
      if (!active.current) return
      setPhase('idle')
      if (submitOnEnd.current && heard.current.trim()) void submission.current(heard.current)
      submitOnEnd.current = false
    }
    recognition.current = next
    try {
      next.start()
      setPhase('listening')
    } catch {
      recognition.current = null
      setError(t('Microphone access isn’t available. You can type your message instead.'))
    }
  }

  const sendForm = (event: FormEvent) => {
    event.preventDefault()
    void submit(transcript)
  }

  const toggleMute = () => {
    const value = !mute.current
    mute.current = value
    setMuted(value)
    if (value) stopSpeaking()
  }

  useSpeakingLevel(orb, speaker, phase === 'speaking')

  const orbState = error && phase === 'idle' ? 'error' : phase
  // The status box shows only while Ada is working: the server's current step, or a plain fallback.
  const working = activity?.trim() || (phase === 'thinking' ? t('Thinking') : '')
  const label = phase === 'listening' ? t('Listening…') : phase === 'thinking' ? t('Ada is working…') : phase === 'speaking' ? t('Ada is speaking') : t('Talk with Ada')
  return <div className="co-voice" ref={root} role="dialog" aria-modal="true" aria-labelledby="co-voice-title">
    <header className="co-voice-head"><span className="co-brand-mark">A</span><div><b id="co-voice-title">{t('Voice with Ada')}</b><small>{t('One conversation, brought to life')}</small></div><button className="co-icon-button" aria-label={t('Return to chat')} onClick={close}><Icon name="close" /></button></header>
    <main className="co-voice-stage">
      <span className="co-kicker">{label}</span>
      <button ref={orb} className={`co-voice-orb ${orbState}`} style={phase === 'listening' ? { ['--level' as string]: recorder.level } : undefined} onClick={listen} disabled={phase === 'thinking' || phase === 'speaking' || recorder.state === 'starting'} aria-label={phase === 'listening' ? t('Finish speaking') : t('Start listening')}><span>A</span><i /><i /><i /><b className="co-orb-arc" aria-hidden="true" /><b className="co-orb-ripple" aria-hidden="true" /></button>
      <div className={`co-voice-status ${working ? 'on' : ''}`} role="status" aria-live="polite">{working ? <><i aria-hidden="true" /><span key={working}>{working}</span></> : null}</div>
      <h1>{phase === 'listening' ? t('I’m listening') : phase === 'thinking' ? t('Finding your answer') : phase === 'speaking' ? t('Here’s what I found') : t('What can I help with?')}</h1>
      <p className="co-voice-transcript">{transcript || (phase === 'listening' ? t('Speak naturally. I’ll send your message when you finish.') : t('Start listening, or use the keyboard below.'))}</p>
      {response ? <div className="co-voice-response"><b>Ada</b><p>{response}</p></div> : null}
      {error ? <p className="co-voice-error" role="alert">{error}</p> : null}
      {!supported ? <p className="co-voice-hint"><Icon name="keyboard" size={15} />{t('Voice recognition isn’t supported here. Type below for the same full-screen conversation.')}</p> : null}
      {!speechOutput ? <p className="co-voice-hint">{t('Spoken replies aren’t supported here. Ada’s responses will appear as text.')}</p> : null}
    </main>
    <footer className="co-voice-controls">
      <form onSubmit={sendForm}><Icon name="keyboard" size={17} /><input autoComplete="off" value={transcript} onChange={(event) => setTranscript(event.target.value)} aria-label={t('Message Ada with your keyboard')} placeholder={t('Type a message to Ada…')} maxLength={20000} disabled={phase === 'thinking'} /><button className="co-icon-button" type="submit" aria-label={t('Send message')} disabled={phase === 'thinking' || !transcript.trim()}><Icon name="arrow" size={17} /></button></form>
      <div className="co-voice-buttons"><button className="co-secondary-button" disabled={!speechOutput} aria-pressed={muted} onClick={toggleMute}><Icon name="mic" size={15} />{muted ? t('Unmute Ada') : t('Mute Ada')}</button>{phase === 'listening' || phase === 'speaking' ? <button className="co-secondary-button" onClick={phase === 'listening' ? listen : stopSpeaking}><Icon name="stop" size={13} />{phase === 'listening' ? t('Finish speaking') : t('Stop speaking')}</button> : null}<button className="co-secondary-button" onClick={close}>{t('Return to chat')}</button></div>
    </footer>
  </div>
}

/** True when a streaming reply no longer continues what came before: it was cleared, or new text replaced it. */
export function startedOver(previous: string, next: string): boolean {
  if (!previous) return false
  if (!next.trim()) return true
  const shared = Math.min(previous.length, next.length, 60)
  return previous.slice(0, shared).trimEnd() !== next.slice(0, shared).trimEnd()
}
