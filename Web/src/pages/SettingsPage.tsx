import { useCallback, useEffect, useState } from 'react'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { Ack, ProviderConfig, ProviderStatus, ProviderTestResult } from '../api/types'
import { ErrorBanner, Spinner } from '../components/ui'

const BLANK: ProviderConfig = { id: '', name: '', kind: 'openAICompatible', baseURL: 'https://', models: [], defaultModel: '' }

/** Admin only: provider configs and the API keys stored on the server. Keys are write-only from here. */
export function SettingsPage() {
  useDocumentTitle('Providers')
  const [providers, setProviders] = useState<ProviderStatus[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [adding, setAdding] = useState(false)

  const load = useCallback(async () => {
    try {
      setProviders(await api<ProviderStatus[]>('providers'))
    } catch (err) {
      setError(errorMessage(err))
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">Server settings</div>
          <h1>Model providers</h1>
          <p className="lede">
            Keys are stored on the server and shared by every mission. They can be replaced or removed here, but never read back.
          </p>
        </div>
        <button className="btn ghost" onClick={() => setAdding(true)} disabled={adding}>
          Add provider
        </button>
      </div>
      <ErrorBanner message={error} />
      {adding ? (
        <ProviderCard
          status={{ provider: BLANK, hasKey: false }}
          isNew
          onSaved={() => {
            setAdding(false)
            void load()
          }}
          onCancel={() => setAdding(false)}
        />
      ) : null}
      {!providers ? <Spinner /> : providers.map((p) => <ProviderCard key={p.provider.id} status={p} onSaved={() => void load()} />)}
    </>
  )
}

export function ProviderCard({
  status,
  isNew = false,
  onSaved,
  onCancel,
}: {
  status: ProviderStatus
  isNew?: boolean
  onSaved: () => void
  onCancel?: () => void
}) {
  const [config, setConfig] = useState<ProviderConfig>(status.provider)
  const [modelsText, setModelsText] = useState(status.provider.models.join(', '))
  const [editing, setEditing] = useState(isNew)
  const [key, setKey] = useState('')
  const [result, setResult] = useState<{ ok: boolean; message: string } | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  async function run(label: string, action: () => Promise<{ ok: boolean; message: string } | void>) {
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

  const saveConfig = () =>
    run('save', async () => {
      const models = modelsText.split(',').map((m) => m.trim()).filter(Boolean)
      await api('providers', {
        method: 'POST',
        body: { ...config, models, defaultModel: config.defaultModel || models[0] },
      })
      setEditing(false)
      onSaved()
      return { ok: true, message: 'Provider saved.' }
    })

  const saveKey = () =>
    run('key', async () => {
      const ack = await api<Ack>(`providers/${status.provider.id}/key`, { method: 'POST', body: { key } })
      setKey('')
      onSaved()
      const test = await api<ProviderTestResult>(`providers/${status.provider.id}/test`, { method: 'POST' })
      return { ok: test.ok, message: test.ok ? `${ack.detail ?? 'Key saved'}. ${test.message}` : `Key saved, but the test failed: ${test.message}` }
    })

  return (
    <div className="card stack">
      <div className="row">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h2>{isNew ? 'New provider' : config.name}</h2>
          {!isNew ? (
            <div className="dim mono" style={{ fontSize: 11, overflowWrap: 'anywhere' }}>
              {config.id} · {config.kind === 'anthropic' ? 'Anthropic API' : 'OpenAI-compatible'} · {config.baseURL}
            </div>
          ) : null}
        </div>
        {!isNew ? <span className={status.hasKey ? 'chip em' : 'chip'}>{status.hasKey ? 'key saved' : 'no key'}</span> : null}
      </div>

      {editing ? (
        <div className="grid-3">
          <label className="field">
            <span>Id</span>
            <input className="input" disabled={!isNew} value={config.id} onChange={(e) => setConfig({ ...config, id: e.target.value.toLowerCase() })} placeholder="my-provider" />
          </label>
          <label className="field">
            <span>Name</span>
            <input className="input" value={config.name} onChange={(e) => setConfig({ ...config, name: e.target.value })} />
          </label>
          <label className="field">
            <span>API style</span>
            <select className="select" value={config.kind} onChange={(e) => setConfig({ ...config, kind: e.target.value as ProviderConfig['kind'] })}>
              <option value="openAICompatible">OpenAI-compatible</option>
              <option value="anthropic">Anthropic</option>
            </select>
          </label>
          <label className="field" style={{ gridColumn: 'span 2' }}>
            <span>Base URL</span>
            <input className="input" value={config.baseURL} onChange={(e) => setConfig({ ...config, baseURL: e.target.value })} />
          </label>
          <label className="field">
            <span>Default model</span>
            <input className="input" value={config.defaultModel ?? ''} onChange={(e) => setConfig({ ...config, defaultModel: e.target.value })} />
          </label>
          <label className="field" style={{ gridColumn: '1 / -1' }}>
            <span>Models (comma separated)</span>
            <input className="input" value={modelsText} onChange={(e) => setModelsText(e.target.value)} />
          </label>
        </div>
      ) : (
        <div className="row">
          {config.models.map((m) => (
            <span key={m} className={m === config.defaultModel ? 'chip em' : 'chip'}>
              {m}
            </span>
          ))}
        </div>
      )}

      {!isNew ? (
        <div className="row">
          <input
            className="input mono"
            style={{ flex: '1 1 260px' }}
            type="password"
            autoComplete="off"
            placeholder={status.hasKey ? 'Paste a new key to replace the saved one' : 'Paste API key'}
            value={key}
            onChange={(e) => setKey(e.target.value)}
            aria-label={`API key for ${config.name}`}
          />
          <button className="btn small" disabled={!key.trim() || busy !== null} onClick={() => void saveKey()}>
            {busy === 'key' ? 'Saving…' : 'Save and test key'}
          </button>
          {status.hasKey ? (
            <button
              className="btn small ghost"
              disabled={busy !== null}
              onClick={() =>
                void run('test', async () => api<ProviderTestResult>(`providers/${status.provider.id}/test`, { method: 'POST' }))
              }
            >
              {busy === 'test' ? 'Testing…' : 'Test connection'}
            </button>
          ) : null}
        </div>
      ) : null}

      {result ? <div className={result.ok ? 'notice' : 'error'}>{result.message}</div> : null}

      <div className="row">
        {editing ? (
          <>
            <button className="btn small" disabled={busy !== null} onClick={() => void saveConfig()}>
              Save provider
            </button>
            <button
              className="btn small ghost"
              onClick={() => {
                setConfig(status.provider)
                setModelsText(status.provider.models.join(', '))
                setEditing(false)
                onCancel?.()
              }}
            >
              Cancel
            </button>
          </>
        ) : (
          <button className="pill" onClick={() => setEditing(true)}>
            Edit models and URL
          </button>
        )}
        <span className="spacer" />
        {!isNew && status.hasKey ? (
          <button
            className="pill"
            onClick={() => {
              if (window.confirm(`Remove the saved ${config.name} key? Agents using it will stop working.`)) {
                void run('remove', async () => {
                  await api(`providers/${status.provider.id}/key`, { method: 'DELETE' })
                  onSaved()
                  return { ok: true, message: 'Key removed.' }
                })
              }
            }}
          >
            Remove key
          </button>
        ) : null}
        {!isNew ? (
          <button
            className="pill"
            onClick={() => {
              if (window.confirm(`Delete the ${config.name} provider and its key?`)) {
                void run('delete', async () => {
                  await api(`providers/${status.provider.id}`, { method: 'DELETE' })
                  onSaved()
                })
              }
            }}
          >
            Delete provider
          </button>
        ) : null}
      </div>
    </div>
  )
}
