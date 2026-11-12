import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useI18n } from '../../i18n'
import { voiceTranscript } from '../../lib/coordinator'
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

export function VoiceMode({ onSend, onClose }: { onSend: (text: string, waitForCompletion: boolean) => Promise<string | null>; onClose: () => void }) {
  const { t, lang } = useI18n()
  const [phase, setPhase] = useState<'idle' | 'listening' | 'thinking' | 'speaking'>('idle')
  const [transcript, setTranscript] = useState('')
  const [response, setResponse] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [muted, setMuted] = useState(false)
  const [supported] = useState(() => speechRecognition() !== null)
  const [speechOutput] = useState(() => 'speechSynthesis' in window)
  const root = useRef<HTMLDivElement>(null)
  const recognition = useRef<Recognition | null>(null)
  const heard = useRef('')
  const submitOnEnd = useRef(false)
  const sending = useRef(false)
  const mute = useRef(false)
  const active = useRef(true)
  const submission = useRef<(text: string) => Promise<void>>(async () => {})

  const stopListening = (discard: boolean) => {
    submitOnEnd.current = !discard
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
    if ('speechSynthesis' in window) window.speechSynthesis.cancel()
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
      if ('speechSynthesis' in window) window.speechSynthesis.cancel()
    }
  }, [])

  const speak = (text: string) => {
    if (mute.current || !speechOutput) {
      setPhase('idle')
      return
    }
    const utterance = new SpeechSynthesisUtterance(voiceTranscript(text) || t('Your response is ready in the chat.'))
    utterance.lang = lang === 'es' ? 'es-ES' : 'en-US'
    utterance.onend = () => { if (active.current) setPhase('idle') }
    utterance.onerror = () => { if (active.current) setPhase('idle') }
    setPhase('speaking')
    window.speechSynthesis.speak(utterance)
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
      const answer = await onSend(text, true)
      if (!active.current) return
      if (!answer?.trim()) {
        setPhase('idle')
        setError(t('Ada couldn’t complete that response. Return to chat for details, or try again.'))
        return
      }
      setResponse(answer)
      speak(answer)
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
      const current = recognition.current
      if (current) current.stop()
      return
    }
    if (sending.current) return
    stopSpeaking()
    const Constructor = speechRecognition()
    if (!Constructor) {
      setError(t('Voice recognition isn’t available in this browser. You can still type to Ada here.'))
      return
    }
    setError(null)
    setResponse('')
    heard.current = ''
    setTranscript('')
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

  const label = phase === 'listening' ? t('Listening…') : phase === 'thinking' ? t('Ada is working…') : phase === 'speaking' ? t('Ada is speaking') : t('Talk with Ada')
  return <div className="co-voice" ref={root} role="dialog" aria-modal="true" aria-labelledby="co-voice-title">
    <header className="co-voice-head"><span className="co-brand-mark">A</span><div><b id="co-voice-title">{t('Voice with Ada')}</b><small>{t('One conversation, brought to life')}</small></div><button className="co-icon-button" aria-label={t('Return to chat')} onClick={close}><Icon name="close" /></button></header>
    <main className="co-voice-stage">
      <span className="co-kicker">{label}</span>
      <button className={`co-voice-orb ${phase}`} onClick={listen} disabled={phase === 'thinking' || phase === 'speaking'} aria-label={phase === 'listening' ? t('Finish speaking') : t('Start listening')}><span>A</span><i /><i /><i /></button>
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
