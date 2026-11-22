import { useEffect, useState } from 'react'
import { api, errorMessage } from '../api/client'
import { useI18n } from '../i18n'
import { Icon } from './coordinator/Icon'
import { ErrorBanner } from './ui'

interface WorkstationView { enabled: boolean; location: string; ssh?: string; publicKey?: string }

/** For admins: where Ada's workstation is, the SSH key to install there, and a connection test. */
export function WorkstationCard() {
  const { t } = useI18n()
  const [view, setView] = useState<WorkstationView | null>(null)
  const [output, setOutput] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [copied, setCopied] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => { void api<WorkstationView>('access/workstation').then(setView).catch(() => setView(null)) }, [])
  if (!view?.enabled) return null
  const test = async () => {
    setBusy(true)
    setError(null)
    try {
      const result = await api<{ ok: boolean; output: string }>('access/workstation/test', { method: 'POST' })
      setOutput(result.output)
      if (!result.ok) setError(t('Ada could not reach her workstation. Check the key and address.'))
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const copy = () => { if (view.publicKey) void navigator.clipboard?.writeText(view.publicKey).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 1500) }) }
  return <div className="co-setting-card workstation-card">
    <div className="co-setting-row">
      <div>
        <b>{t('Ada’s workstation')}</b>
        <p>{t('Commands run on {location}. Each one asks for your approval unless a rule below allows it.', { location: view.location })}</p>
      </div>
      <button className="co-secondary-button" disabled={busy} onClick={() => void test()}><Icon name="terminal" size={14} />{t('Test connection')}</button>
    </div>
    {view.publicKey ? <div className="workstation-key">
      <p>{t('Add this key to ~/.ssh/authorized_keys for {user} on that machine:', { user: view.ssh ?? '' })}</p>
      <div className="row"><code>{view.publicKey}</code><button className="co-text-button" onClick={copy} aria-label={t('Copy key')} title={t('Copy key')}><Icon name={copied ? 'check' : 'copy'} size={12} /></button></div>
    </div> : null}
    {output ? <pre className="co-action-result">{output}</pre> : null}
    <ErrorBanner message={error} />
  </div>
}
