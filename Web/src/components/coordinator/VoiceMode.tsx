import { useCallback, useEffect, useLayoutEffect, useRef, useState, type FormEvent, type ReactNode } from 'react'
import { useI18n } from '../../i18n'
import { api } from '../../api/client'
import type { VoiceInfo } from '../../api/chatTypes'
import { takeSpeakable } from '../../lib/coordinator'
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

interface SpokenPiece {
  text: string
  /** The server speech endpoint it was read with; without one the browser voice reads it. */
  url?: string
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
  /** A few words to say right away while Ada works, written by a quick model call. */
  ack?: string
  /** Where to POST a sentence to have the server speak it. */
  speechPath: string
}

/** A short pause between Ada going quiet and the microphone opening, so the tail of her voice isn't recorded. */
export const MIC_AFTER_SPEECH_MS = 200

/** Wait this long before saying anything while Ada works, so an instant answer isn't preceded by filler. */
export const ACK_AFTER_MS = 1000
/** If the quick model hasn't written an acknowledgement by now, say one of the app's own. */
export const ACK_FALLBACK_MS = 2600
/** While Ada works quietly, say how it's going this often at most, and only a few times per answer. */
export const PROGRESS_EVERY_MS = 12_000
export const MAX_PROGRESS_CUES = 2

const FALLBACK_ACKS: Record<'en' | 'es', string[]> = {
  en: ['Let me check that.', 'One moment.', 'On it.', 'Let me look into that.', 'Give me a second.'],
  es: ['Déjame revisarlo.', 'Un momento.', 'Ahora mismo.', 'Voy a mirarlo.', 'Dame un segundo.'],
}
let fallbackTurn = 0

/** The app's own acknowledgement, a different one each time. */
export function fallbackAck(lang: 'en' | 'es'): string {
  const lines = FALLBACK_ACKS[lang]
  fallbackTurn += 1
  return lines[fallbackTurn % lines.length]!
}

/** A short spoken progress line from what Ada is doing right now ("Searching Gmail"). */
export function progressCue(lang: 'en' | 'es', activity: string | null): string {
  const step = activity?.trim().replace(/[.…]+$/, '')
  if (lang === 'es') return step ? `Sigo en ello: ${step.charAt(0).toLowerCase()}${step.slice(1)}.` : 'Sigo trabajando en ello.'
  return step ? `Still on it, ${step.charAt(0).toLowerCase()}${step.slice(1)}.` : 'Still working on it.'
}

/** Why the orb is idle, which decides the hint under it. */
type Rest = 'start' | 'replied' | 'no-speech'

function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

/**
 * Feeds a live sound level (the microphone while listening, Ada's voice while speaking) into the
 * orb's `--level`, smoothed so the orb swells with the sound instead of flickering. Writes the style
 * directly to skip re-renders; the CSS turns it into scale and opacity, which never repaint.
 */
function useOrbLevel(orb: { current: HTMLElement | null }, read: (() => number) | null) {
  useEffect(() => {
    const element = orb.current
    if (!read || !element || prefersReducedMotion() || typeof window.requestAnimationFrame !== 'function') return
    let smoothed = 0
    let frame = 0
    const tick = () => {
      const level = Math.max(0, Math.min(1, read()))
      // Rise quickly with a syllable, settle slowly after it.
      smoothed += (level - smoothed) * (level > smoothed ? 0.45 : 0.12)
      element.style.setProperty('--level', smoothed.toFixed(3))
      // Once there is a real level to follow, keep following it through quiet moments, rather than
      // flicking back to the stand-in sway between words.
      if (level > 0) element.setAttribute('data-metered', '')
      frame = window.requestAnimationFrame(tick)
    }
    frame = window.requestAnimationFrame(tick)
    return () => {
      window.cancelAnimationFrame(frame)
      element.style.removeProperty('--level')
      element.removeAttribute('data-metered')
    }
  }, [orb, read])
}

/** What the conversation beside the orb can do through voice mode. */
export interface VoiceChatHandlers {
  /** Sends a message as if it were spoken, so Ada answers out loud. */
  send: (text: string) => void
  /** Puts text in the keyboard box to edit before sending. */
  edit: (text: string) => void
}

export function VoiceMode({ onSend, onTranscribe, onClose, activity = null, transcript: conversation = null }: { onSend: (text: string, waitForCompletion: boolean, onPartial?: (update: VoicePartial) => void, includePhotos?: boolean) => Promise<VoiceReply | null>; onTranscribe: (audio: Blob) => Promise<string>; onClose: () => void; /** What Ada is doing right now, such as "Searching Gmail"; null while she isn't working. */ activity?: string | null; /** The chat itself (messages, copy, approval cards), shown beside the orb once there is one. */ transcript?: ((handlers: VoiceChatHandlers) => ReactNode) | null }) {
  const { t, lang } = useI18n()
  const [phase, setPhase] = useState<'idle' | 'listening' | 'thinking' | 'speaking'>('idle')
  const [rest, setRest] = useState<Rest>('start')
  const [transcript, setTranscript] = useState('')
  /** What the user last said or typed, shown while Ada answers so they can check she heard them right. */
  const [said, setSaid] = useState('')
  const [response, setResponse] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [muted, setMuted] = useState(false)
  const [voiceInfo, setVoiceInfo] = useState<VoiceInfo | null>(null)
  /** True once the server has said which voice services it has (or couldn't be asked), so listening can start. */
  const [voiceReady, setVoiceReady] = useState(false)
  const [browserRecognition] = useState(() => speechRecognition() !== null)
  const serverListening = Boolean(voiceInfo?.setup.stt && canRecord())
  const supported = serverListening || browserRecognition
  const speechOutput = Boolean(voiceInfo?.setup.tts) || 'speechSynthesis' in window
  const root = useRef<HTMLDivElement>(null)
  const orb = useRef<HTMLButtonElement>(null)
  const keyboard = useRef<HTMLInputElement>(null)
  const recognition = useRef<Recognition | null>(null)
  const speaker = useRef<Speaker | null>(null)
  const heard = useRef('')
  const submitOnEnd = useRef(false)
  const sending = useRef(false)
  const mute = useRef(false)
  const active = useRef(true)
  const submission = useRef<(text: string) => Promise<void>>(async () => {})
  /** Closes the microphone. Called whenever Ada starts speaking, so she never hears herself. */
  const closeMic = useRef<() => void>(() => undefined)
  const startListening = useRef<() => void>(() => undefined)
  const autoListened = useRef(false)
  const micTimer = useRef<number | null>(null)
  /** Set when they stop Ada mid-reply, so the rest of that reply isn't read out as it arrives. */
  const hushed = useRef(false)
  const activityNow = useRef<string | null>(activity)
  activityNow.current = activity
  /** What Ada said for the last reply, piece by piece, so Replay can read it again the same way. */
  const spoken = useRef<SpokenPiece[]>([])
  const [canReplay, setCanReplay] = useState(false)
  if (!speaker.current) {
    speaker.current = new Speaker(lang === 'es' ? 'es-ES' : 'en-US')
    speaker.current.onChange = (speaking) => {
      if (!active.current) return
      if (speaking) closeMic.current()
      setPhase(speaking ? 'speaking' : sending.current ? 'thinking' : 'idle')
    }
  }
  const recorder = useRecorder((audio, duration, ended) => {
    if (!active.current || !submitOnEnd.current) return
    submitOnEnd.current = false
    if (ended === 'no-speech') {
      // Nothing was said: close the microphone quietly instead of sending silence to be transcribed.
      setPhase('idle')
      setRest('no-speech')
      return
    }
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
    if (micTimer.current !== null) window.clearTimeout(micTimer.current)
    micTimer.current = null
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

  // Voice mode opens from a tap, and this runs inside it, so iOS will let Ada's first reply play.
  useLayoutEffect(() => {
    speaker.current?.unlock()
  }, [])

  useEffect(() => {
    active.current = true
    void api<VoiceInfo>('voice').then((info) => {
      if (active.current) setVoiceInfo(info)
    }).catch(() => undefined).finally(() => {
      if (active.current) setVoiceReady(true)
    })
    return () => {
      active.current = false
      submitOnEnd.current = false
      if (micTimer.current !== null) window.clearTimeout(micTimer.current)
      micTimer.current = null
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

  // Voice mode is for talking, so it opens listening. This happens once; after that the orb starts it.
  useEffect(() => {
    if (!voiceReady || autoListened.current) return
    autoListened.current = true
    // Skip it if they already started: tapped the orb, typed, or sent something while it loaded.
    if (supported && phase === 'idle' && !transcript) startListening.current()
    // Only voiceReady should trigger this; phase and transcript are read as they are at that moment.
  }, [voiceReady, supported])

  /** Remembers a piece of the reply for Replay, and speaks it unless Ada is muted. */
  const say = (text: string, url?: string) => {
    spoken.current.push({ text, url })
    setCanReplay(true)
    if (!mute.current && !hushed.current) speaker.current?.enqueueText(text, url)
  }

  /** Stops Ada talking. Mid-reply, the rest of that reply stays quiet too (it is still on screen). */
  const hush = () => {
    if (sending.current) hushed.current = true
    stopSpeaking()
  }

  /** Reads Ada's last reply again, through the same voice path (server speech fixes numbers and money). */
  const replay = () => {
    const pieces = spoken.current
    if (!pieces.length || sending.current) return
    stopListening(true)
    speaker.current?.stop()
    speaker.current?.unlock()
    setError(null)
    for (const piece of pieces) speaker.current?.enqueueText(piece.text, piece.url)
  }

  /** Speaks each finished sentence as Ada writes it, instead of waiting for the whole reply. */
  const streamSpeech = () => {
    let from = 0
    let previous = ''
    let spoke = false
    const startedAt = Date.now()
    let acknowledged = false
    let lastVoiced = startedAt
    let cues = 0
    let lastCue: string | null = null
    /** Says a short filler line (not part of the answer, so Replay skips it) unless Ada is quiet on purpose. */
    const fill = (line: string, speechPath: string) => {
      if (mute.current || hushed.current) return
      lastVoiced = Date.now()
      speaker.current?.enqueueText(line, voiceInfo?.setup.tts ? speechPath : undefined)
    }
    return ({ text, speech, ack, final, speechPath }: VoicePartial) => {
      if (!active.current) return
      setResponse(text)
      // While nothing of the answer is ready, let them know she's on it, then how it's going.
      if (speechOutput && !spoke && !final && !speaker.current?.speaking) {
        const waited = Date.now() - startedAt
        if (!acknowledged && waited >= ACK_AFTER_MS && (ack || waited >= ACK_FALLBACK_MS)) {
          acknowledged = true
          fill(ack || fallbackAck(lang === 'es' ? 'es' : 'en'), speechPath)
        } else if (acknowledged && cues < MAX_PROGRESS_CUES && Date.now() - lastVoiced >= PROGRESS_EVERY_MS) {
          const step = activityNow.current
          if (step !== lastCue || cues === 0) {
            cues += 1
            lastCue = step
            fill(progressCue(lang === 'es' ? 'es' : 'en', step), speechPath)
          }
        }
      }
      if (text) markVoice('reply-first-text')
      if (final) markVoice('reply-complete')
      if (!speechOutput) return
      // A voice reply is read in full, so the chat and the voice say the same thing. Older replies
      // kept a separate spoken part; that is still honoured for them.
      const source = speech ?? text
      const done = final || speech !== undefined
      // Text Ada wrote before using a tool is replaced by the real answer. Start again from its top,
      // or the opening of the answer would be skipped.
      if (startedOver(previous, source)) from = 0
      previous = source
      const words = lang === 'es' ? 'es' : 'en'
      for (let next = takeSpeakable(source, from, done, undefined, undefined, words); next; next = takeSpeakable(source, from, done, undefined, undefined, words)) {
        from = next.end
        if (!next.text) continue
        spoke = true
        markVoice('first-sentence')
        say(next.text, voiceInfo?.setup.tts ? speechPath : undefined)
      }
      if (final && !spoke) say(t('Your response is ready in the chat.'))
    }
  }

  /** Sends a message and speaks the answer. Photos waiting in the chat composer go with what they say or type, not with picks from the chat. */
  const submit = async (raw: string, includePhotos = true) => {
    const text = raw.trim()
    if (!text || sending.current) return
    autoListened.current = true
    stopListening(true)
    stopSpeaking()
    sending.current = true
    hushed.current = false
    spoken.current = []
    setCanReplay(false)
    setSaid(text)
    setTranscript('')
    setResponse('')
    setError(null)
    setPhase('thinking')
    try {
      const answer = await onSend(text, true, streamSpeech(), includePhotos)
      if (!active.current) return
      if (!answer?.text.trim()) {
        setPhase('idle')
        setError(t('Ada couldn’t complete that response. Return to chat for details, or try again.'))
        return
      }
      setResponse(answer.text)
      setRest('replied')
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

  /**
   * The orb: tap to talk, tap again to finish. Tapping while Ada speaks cuts her off and listens;
   * while she is still writing the reply, it only stops her talking, since a new message can't be
   * sent until she finishes.
   */
  const listen = () => {
    autoListened.current = true
    if (phase === 'listening') {
      // Still waiting on the microphone (or the pause after Ada): just stand down.
      if (micTimer.current !== null || recorder.state === 'starting') return stopListening(true)
      if (serverListening) recorder.stop()
      else recognition.current?.stop()
      return
    }
    if (sending.current) return hush()
    if (micTimer.current !== null) return
    const wasSpeaking = speaker.current?.speaking ?? false
    stopSpeaking()
    speaker.current?.unlock()
    if (!wasSpeaking) return openMic()
    // Give the speakers a moment to go quiet, so the end of Ada's sentence isn't recorded.
    setPhase('listening')
    micTimer.current = window.setTimeout(() => {
      micTimer.current = null
      if (active.current && !sending.current) openMic()
    }, MIC_AFTER_SPEECH_MS)
  }

  const openMic = () => {
    // Never record over Ada (a reply or a Replay), over a message on its way, or twice at once.
    if (speaker.current?.speaking || sending.current || recognition.current || recorder.state !== 'idle') return
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
    next.onerror = (event) => {
      submitOnEnd.current = false
      if (!active.current) return
      setPhase('idle')
      // Nobody spoke, or listening was cut off on purpose: just close the microphone.
      if (event.error === 'no-speech' || event.error === 'aborted') setRest('no-speech')
      else setError(t('I couldn’t hear that. Check microphone access, or type your message instead.'))
    }
    next.onend = () => {
      recognition.current = null
      if (!active.current) return
      setPhase('idle')
      if (submitOnEnd.current && heard.current.trim()) void submission.current(heard.current)
      else if (submitOnEnd.current) setRest('no-speech')
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

  startListening.current = openMic
  closeMic.current = () => {
    if (recognition.current || recorder.state !== 'idle' || micTimer.current !== null) stopListening(true)
  }

  /** Typing means they'd rather not talk: close the microphone, keeping what is in the box. */
  const typing = () => {
    autoListened.current = true
    if (phase !== 'listening') return
    const draft = transcript
    stopListening(true)
    setTranscript(draft)
  }

  const chatHandlers: VoiceChatHandlers = {
    send: (text) => void submit(text, false),
    edit: (text) => {
      autoListened.current = true
      stopListening(true)
      setTranscript(text)
      keyboard.current?.focus()
    },
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

  const readSpeaking = useCallback(() => speaker.current?.level() ?? 0, [])
  useOrbLevel(orb, phase === 'listening' ? recorder.readLevel : phase === 'speaking' ? readSpeaking : null)

  const orbState = error && phase === 'idle' ? 'error' : phase
  // The status box shows only while Ada is working: the server's current step, or a plain fallback.
  const working = activity?.trim() || (phase === 'thinking' ? t('Thinking') : '')
  const label = phase === 'listening' ? t('Listening…') : phase === 'thinking' ? t('Thinking…') : phase === 'speaking' ? t('Speaking') : orbState === 'error' ? t('Something went wrong') : t('Ready')
  const heading = phase === 'listening' ? t('I’m listening') : phase === 'thinking' ? t('Finding your answer') : phase === 'speaking' ? sending.current && !canReplay ? t('Finding your answer') : t('Here’s what I found') : rest === 'replied' ? t('Anything else?') : t('What can I help with?')
  const hint = phase === 'listening'
    ? t('Speak naturally. I’ll send your message when you finish.')
    : phase === 'idle'
      ? !supported ? t('Use the keyboard below.') : rest === 'replied' ? t('Tap the orb to reply.') : rest === 'no-speech' ? t('I stopped listening. Tap the orb when you’re ready.') : t('Tap the orb to talk, or use the keyboard below.')
      : ''
  const orbLabel = phase === 'listening' ? t('Finish speaking') : phase === 'speaking' ? sending.current ? t('Stop speaking') : t('Stop Ada and talk') : t('Start listening')
  const showReplay = canReplay && speechOutput && phase !== 'thinking'
  const chat = conversation?.(chatHandlers) ?? null
  return <div className={`co-voice ${chat ? 'with-chat' : ''}`} ref={root} role="dialog" aria-modal="true" aria-labelledby="co-voice-title">
    <header className="co-voice-head"><span className="co-brand-mark">A</span><div><b id="co-voice-title">{t('Voice with Ada')}</b><small>{t('One conversation, brought to life')}</small></div><button className="co-icon-button" aria-label={t('Return to chat')} onClick={close}><Icon name="close" /></button></header>
    <div className="co-voice-body">
    <main className="co-voice-stage">
      <span className={`co-voice-state ${orbState}`} aria-live="polite"><i aria-hidden="true" />{label}</span>
      <button ref={orb} className={`co-voice-orb ${orbState}`} onClick={listen} disabled={phase === 'thinking' || recorder.state === 'starting'} aria-label={orbLabel}><b className="co-orb-glow" aria-hidden="true" /><b className="co-orb-core" aria-hidden="true" /><span>A</span><i /><i /><i /><b className="co-orb-bars" aria-hidden="true"><i /><i /><i /><i /><i /></b><b className="co-orb-arc" aria-hidden="true" /><b className="co-orb-ripple" aria-hidden="true" /><b className="co-orb-ripple late" aria-hidden="true" /></button>
      <div className={`co-voice-status ${working ? 'on' : ''}`} role="status" aria-live="polite">{working ? <><i aria-hidden="true" /><span key={working}>{working}</span></> : null}</div>
      <h1>{heading}</h1>
      {said && !chat && phase !== 'listening' ? <p className="co-voice-said"><b>{t('You')}</b>{said}</p> : null}
      {(phase === 'listening' && transcript) || hint ? <p className="co-voice-transcript">{phase === 'listening' && transcript ? transcript : hint}</p> : null}
      {showReplay ? <button className={`co-voice-replay ${phase === 'speaking' ? 'playing' : ''}`} onClick={phase === 'speaking' ? hush : replay} aria-label={phase === 'speaking' ? t('Stop speaking') : undefined}><Icon name={phase === 'speaking' ? 'stop' : 'play'} size={phase === 'speaking' ? 13 : 15} />{phase === 'speaking' ? t('Stop') : t('Replay answer')}</button> : null}
      {response && !chat ? <div className="co-voice-response"><b>Ada</b><p>{response}</p></div> : null}
      {error ? <p className="co-voice-error" role="alert">{error}</p> : null}
      {!supported ? <p className="co-voice-hint"><Icon name="keyboard" size={15} />{t('Voice recognition isn’t supported here. Type below for the same full-screen conversation.')}</p> : null}
      {!speechOutput ? <p className="co-voice-hint">{t('Spoken replies aren’t supported here. Ada’s responses will appear as text.')}</p> : null}
    </main>
    {chat ? <aside className="co-voice-chat" aria-label={t('Conversation')}>{chat}</aside> : null}
    </div>
    <footer className="co-voice-controls">
      <form onSubmit={sendForm}><Icon name="keyboard" size={17} /><input ref={keyboard} autoComplete="off" value={transcript} onFocus={typing} onChange={(event) => { typing(); setTranscript(event.target.value) }} aria-label={t('Message Ada with your keyboard')} placeholder={t('Type a message to Ada…')} maxLength={20000} /><button className="co-icon-button" type="submit" aria-label={t('Send message')} disabled={phase === 'thinking' || !transcript.trim()}><Icon name="arrow" size={17} /></button></form>
      <div className="co-voice-buttons"><button className="co-secondary-button" disabled={!speechOutput} aria-pressed={muted} onClick={toggleMute}><Icon name="mic" size={15} />{muted ? t('Unmute Ada') : t('Mute Ada')}</button>{phase === 'listening' ? <button className="co-secondary-button" onClick={listen}><Icon name="stop" size={13} />{t('Finish speaking')}</button> : null}<button className="co-secondary-button" onClick={close}>{t('Return to chat')}</button></div>
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
