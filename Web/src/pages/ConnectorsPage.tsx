import { useCallback, useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { Ack, ConnectorId, ConnectorPermissions, ConnectorStatus, ConnectorTestResult } from '../api/types'
import { ErrorBanner, Spinner } from '../components/ui'

const ORDER: ConnectorId[] = ['gmail', 'googleads', 'web', 'cloudflare']

type Result = { ok: boolean; message: string } | null

/** Admin only: the outside tools mission agents can use (Gmail, Google Ads, the web, Cloudflare). */
export function ConnectorsPage() {
  useDocumentTitle('Connectors')
  const [connectors, setConnectors] = useState<ConnectorStatus[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [params, setParams] = useSearchParams()
  const connected = params.get('connected')

  const load = useCallback(async () => {
    try {
      const list = await api<ConnectorStatus[]>('connectors')
      list.sort((a, b) => ORDER.indexOf(a.id) - ORDER.indexOf(b.id))
      setConnectors(list)
    } catch (err) {
      setError(errorMessage(err))
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const connectedName = connectors?.find((c) => c.id === connected)?.name

  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">Server settings</div>
          <h1>Connectors</h1>
          <p className="lede">
            Tools mission agents can use beyond their own files. Anything that sends or changes something stays off until you switch it on.
          </p>
        </div>
      </div>
      <ErrorBanner message={error} />
      {connected && connectedName ? (
        <div className="notice row">
          <span style={{ flex: 1 }}>{connectedName} is connected.</span>
          <button className="pill" onClick={() => setParams({})}>
            Dismiss
          </button>
        </div>
      ) : null}
      {!connectors ? <Spinner /> : connectors.map((c) => <ConnectorCard key={c.id} status={c} onChanged={() => void load()} />)}
    </>
  )
}

function ConnectorCard({ status, onChanged }: { status: ConnectorStatus; onChanged: () => void }) {
  const [result, setResult] = useState<Result>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [secret, setSecret] = useState('')
  const [developerToken, setDeveloperToken] = useState('')
  const [customerId, setCustomerId] = useState('')
  const isGoogle = status.id === 'gmail' || status.id === 'googleads'

  async function run(label: string, action: () => Promise<Result | void>) {
    setBusy(label)
    setResult(null)
    try {
      const outcome = await action()
      if (outcome) setResult(outcome)
    } catch (err) {
      setResult({ ok: false, message: errorMessage(err) })
    } finally {
      setBusy(null)
    }
  }

  const patch = (body: { enabled?: boolean; permissions?: ConnectorPermissions }) =>
    run('patch', async () => {
      await api(`connectors/${status.id}`, { method: 'PATCH', body })
      onChanged()
    })

  const connectGoogle = () =>
    run('connect', async () => {
      const { url } = await api<{ url: string }>(`connectors/${status.id}/authorize`, { method: 'POST', body: { clientKind: 'browser' } })
      window.location.assign(url)
    })

  const test = () => run('test', async () => api<ConnectorTestResult>(`connectors/${status.id}/test`, { method: 'POST' }))

  const saveSecret = (path: string, label: string) =>
    run('secret', async () => {
      const ack = await api<Ack>(path, { method: 'POST', body: { key: secret } })
      setSecret('')
      onChanged()
      return { ok: true, message: ack.detail ?? `${label} saved.` }
    })

  const saveAds = () =>
    run('ads', async () => {
      const ack = await api<Ack>('connectors/googleads/credentials', { method: 'POST', body: { developerToken, customerId } })
      setDeveloperToken('')
      setCustomerId('')
      onChanged()
      return { ok: true, message: ack.detail ?? 'Saved.' }
    })

  const connectedLabel =
    status.id === 'web' ? (status.configured ? 'fetch and search' : 'fetch only') : status.configured ? 'connected' : 'not connected'
  const p = status.permissions

  return (
    <div className="card stack">
      <div className="row">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h2>{status.name}</h2>
          <div className="dim" style={{ fontSize: 13 }}>
            {status.detail}
          </div>
        </div>
        <span className={(status.configured || status.id === 'web') && status.enabled ? 'chip em' : 'chip'}>{status.enabled ? connectedLabel : 'off'}</span>
      </div>

      {isGoogle && !status.oauthAvailable ? (
        <div className="notice">
          Google sign-in isn't set up on this server. Create a Google Cloud OAuth client of type Web application, add{' '}
          <span className="mono">{`${window.location.origin}/api/connectors/${status.id}/callback`}</span> as a redirect URI, and set{' '}
          <span className="mono">AGENTSAM_GOOGLE_CLIENT_ID</span> and <span className="mono">AGENTSAM_GOOGLE_CLIENT_SECRET</span> in
          Railway. Set the OAuth consent screen to In production, or Google signs you out every 7 days.
        </div>
      ) : null}

      {status.id === 'googleads' ? (
        <div className="dim" style={{ fontSize: 12 }}>
          Ads API access now comes from your Google Cloud project: enable the Google Ads API there, and apply for Explorer access or higher to read live accounts.
        </div>
      ) : null}

      {status.id === 'googleads' ? (
        <div className="grid-3">
          <label className="field">
            <span>Developer token (optional)</span>
            <input className="input mono" type="password" autoComplete="off" value={developerToken} onChange={(e) => setDeveloperToken(e.target.value)} placeholder="Only for older Ads API setups" />
          </label>
          <label className="field">
            <span>Manager (login) customer ID</span>
            <input className="input mono" value={customerId} onChange={(e) => setCustomerId(e.target.value)} placeholder="123-456-7890, optional" />
          </label>
          <div className="field" style={{ justifyContent: 'flex-end' }}>
            <button className="btn small" disabled={(!developerToken.trim() && !customerId.trim()) || busy !== null} onClick={() => void saveAds()}>
              {busy === 'ads' ? 'Saving…' : 'Save'}
            </button>
          </div>
        </div>
      ) : null}

      {status.id === 'web' || status.id === 'cloudflare' ? (
        <div className="row">
          <input
            className="input mono"
            style={{ flex: '1 1 260px' }}
            type="password"
            autoComplete="off"
            placeholder={status.id === 'web' ? 'Brave Search API key, to turn on web search' : 'Cloudflare API token'}
            value={secret}
            onChange={(e) => setSecret(e.target.value)}
            aria-label={status.id === 'web' ? 'Brave Search API key' : 'Cloudflare API token'}
          />
          <button
            className="btn small"
            disabled={!secret.trim() || busy !== null}
            onClick={() =>
              void saveSecret(status.id === 'web' ? 'connectors/web/key' : 'connectors/cloudflare/token', status.id === 'web' ? 'Key' : 'Token')
            }
          >
            {busy === 'secret' ? 'Checking…' : 'Check and save'}
          </button>
        </div>
      ) : null}

      <div className="row">
        <Toggle label="Agents can use it" checked={status.enabled} disabled={busy !== null} onChange={(enabled) => void patch({ enabled })} />
        {status.id === 'gmail' ? (
          <>
            <Toggle label="Write drafts" checked={p.createDraft} disabled={busy !== null} onChange={(createDraft) => void patch({ permissions: { ...p, createDraft } })} />
            <Toggle
              label="Send email"
              checked={p.sendEmail}
              disabled={busy !== null}
              onChange={(sendEmail) => {
                if (!sendEmail || window.confirm('Let agents send email from your Gmail account without asking first?')) void patch({ permissions: { ...p, sendEmail } })
              }}
            />
          </>
        ) : null}
        {status.id === 'cloudflare' ? (
          <Toggle label="Change DNS and purge cache" checked={p.dnsWrite} disabled={busy !== null} onChange={(dnsWrite) => void patch({ permissions: { ...p, dnsWrite } })} />
        ) : null}
      </div>
      {status.id === 'gmail' && status.configured ? (
        <div className="dim" style={{ fontSize: 12 }}>
          Turning on drafts or sending after you connect? Connect again so Google grants the extra permission.
        </div>
      ) : null}

      {result ? <div className={result.ok ? 'notice' : 'error'}>{result.message}</div> : null}

      <div className="row">
        {isGoogle ? (
          <button className="btn small" disabled={!status.oauthAvailable || busy !== null} onClick={() => void connectGoogle()}>
            {busy === 'connect' ? 'Opening Google…' : status.configured ? 'Connect again' : 'Connect with Google'}
          </button>
        ) : null}
        {status.configured || status.id === 'web' ? (
          <button className="btn small ghost" disabled={busy !== null} onClick={() => void test()}>
            {busy === 'test' ? 'Testing…' : 'Test'}
          </button>
        ) : null}
        <span className="spacer" />
        {status.configured && status.id !== 'web' ? (
          <button
            className="pill"
            disabled={busy !== null}
            onClick={() => {
              if (window.confirm(`Disconnect ${status.name}? Its saved credentials are removed from the server.`)) {
                void run('disconnect', async () => {
                  const ack = await api<Ack>(`connectors/${status.id}/disconnect`, { method: 'POST' })
                  onChanged()
                  return { ok: true, message: ack.detail ?? 'Disconnected.' }
                })
              }
            }}
          >
            Disconnect
          </button>
        ) : null}
        {status.id === 'web' && status.configured ? (
          <button
            className="pill"
            disabled={busy !== null}
            onClick={() =>
              void run('disconnect', async () => {
                await api<Ack>('connectors/web/disconnect', { method: 'POST' })
                onChanged()
                return { ok: true, message: 'Search key removed. Web fetch stays on.' }
              })
            }
          >
            Remove search key
          </button>
        ) : null}
      </div>
    </div>
  )
}

function Toggle({ label, checked, disabled, onChange }: { label: string; checked: boolean; disabled?: boolean; onChange: (value: boolean) => void }) {
  return (
    <label className="toggle">
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span>{label}</span>
    </label>
  )
}
