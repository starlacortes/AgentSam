import { useEffect, useRef, useState, type FormEvent } from 'react'
import type RFB from '@novnc/novnc'
import { api, errorMessage } from '../../api/client'
import type { BrowserSessionView } from '../../api/types'
import { useI18n } from '../../i18n'
import { ENTER_KEYSYM, liveBrowserURL, typeText } from '../../lib/browser'
import { ErrorBanner, Spinner } from '../ui'
import { Icon } from './Icon'
import { useDialogA11y } from './Overlay'

type Phase = 'starting' | 'connecting' | 'live' | 'ended'

/**
 * The live window onto Ada's browser: a real Chromium window on her workstation, drawn here by
 * noVNC. Opening it starts the browser; it stops by itself when nobody has watched for a while.
 */
export function BrowserWindow({ onClose }: { onClose: () => void }) {
  const { t } = useI18n()
  const dialog = useRef<HTMLDivElement>(null)
  const screen = useRef<HTMLDivElement>(null)
  const client = useRef<RFB | null>(null)
  const [phase, setPhase] = useState<Phase>('starting')
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [text, setText] = useState('')
  const [stopping, setStopping] = useState(false)
  useDialogA11y(dialog, onClose)

  useEffect(() => {
    let cancelled = false
    setPhase('starting')
    setError(null)
    void (async () => {
      try {
        const session = await api<BrowserSessionView>('browser/start', { method: 'POST' })
        // noVNC is only needed here, so it stays out of the app's first download.
        const { default: Client } = await import('@novnc/novnc')
        if (cancelled || !screen.current) return
        setPhase('connecting')
        const rfb = new Client(screen.current, liveBrowserURL(window.location), { credentials: { password: session.password }, shared: true })
        rfb.scaleViewport = true
        rfb.resizeSession = false
        rfb.focusOnClick = true
        rfb.background = 'transparent'
        rfb.addEventListener('connect', () => { if (!cancelled) setPhase('live') })
        rfb.addEventListener('disconnect', () => {
          if (cancelled) return
          client.current = null
          setPhase('ended')
        })
        rfb.addEventListener('securityfailure', () => { if (!cancelled) setError(t('The browser refused the connection. Check the browser password on the server.')) })
        rfb.addEventListener('credentialsrequired', () => { if (!cancelled) setError(t('The browser refused the connection. Check the browser password on the server.')) })
        client.current = rfb
      } catch (err) {
        if (cancelled) return
        setError(errorMessage(err))
        setPhase('ended')
      }
    })()
    return () => {
      cancelled = true
      client.current?.disconnect()
      client.current = null
    }
    // `t` changes identity with the language; reconnecting for that would drop the session.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [attempt])

  const send = (event: FormEvent) => {
    event.preventDefault()
    const rfb = client.current
    if (!rfb) return
    const key = (keysym: number) => { rfb.sendKey(keysym, null, true); rfb.sendKey(keysym, null, false) }
    // An empty box sends Enter, so a phone can submit what it just typed.
    if (text) typeText(key, text)
    else key(ENTER_KEYSYM)
    setText('')
  }

  const stop = async () => {
    setStopping(true)
    try {
      client.current?.disconnect()
      await api('browser/stop', { method: 'POST' })
      onClose()
    } catch (err) {
      setError(errorMessage(err))
      setStopping(false)
    }
  }

  const status = phase === 'live' ? t('Live') : phase === 'ended' ? t('Disconnected') : phase === 'connecting' ? t('Connecting…') : t('Starting the browser…')
  return <div className="co-modal-overlay co-browser-overlay" role="dialog" aria-modal="true" aria-label={t('Ada’s browser')}>
    <div className="co-browser-window" ref={dialog}>
      <header className="co-browser-head">
        <Icon name="monitor" size={18} />
        <div className="co-browser-title">
          <strong>{t('Ada’s browser')}</strong>
          <span className={`co-browser-status ${phase}`} role="status">{status}</span>
        </div>
        <button className="co-secondary-button" type="button" disabled={stopping} onClick={() => void stop()}>{t('Stop the browser')}</button>
        <button className="co-icon-button" type="button" aria-label={t('Close the browser window')} onClick={onClose}><Icon name="close" size={16} /></button>
      </header>
      {error ? <ErrorBanner message={error} /> : null}
      <div className="co-browser-screen" ref={screen}>
        {phase === 'starting' || phase === 'connecting' ? <div className="co-browser-wait"><Spinner />{status}</div> : null}
        {phase === 'ended' ? <div className="co-browser-wait"><p>{t('The live window is not connected.')}</p><button className="co-secondary-button" type="button" onClick={() => setAttempt((count) => count + 1)}>{t('Reconnect')}</button></div> : null}
      </div>
      <form className="co-browser-type" onSubmit={send}>
        <input type="text" value={text} onChange={(event) => setText(event.target.value)} placeholder={t('Type or paste here, then Send. Send with nothing typed presses Enter.')} aria-label={t('Text to type in the browser')} autoCapitalize="off" autoCorrect="off" spellCheck={false} disabled={phase !== 'live'} />
        <button className="co-secondary-button" type="submit" disabled={phase !== 'live'}>{t('Send')}</button>
      </form>
      <p className="co-browser-note">{t('A fresh window for the public web. You are in control; Ada cannot use it yet. Nothing is saved when it stops, and it stops by itself when nobody is watching.')}</p>
    </div>
  </div>
}
