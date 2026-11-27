import { useCallback, useEffect, useState } from 'react'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { Ack, ProviderConfig, ProviderStatus, ProviderTestResult, VisionModelSetting } from '../api/types'
import { ErrorBanner, Spinner } from '../components/ui'
import { useI18n } from '../i18n'

const BLANK: ProviderConfig = { id: '', name: '', kind: 'openAICompatible', baseURL: 'https://', models: [], defaultModel: '' }

/** Admin only: provider configs and the API keys stored on the server. Keys are write-only from here. */
export function ProvidersPage() {
  const { t } = useI18n()
  useDocumentTitle(t('Providers'))
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
          <div className="kicker">{t('Server settings')}</div>
          <h1>{t('Model providers')}</h1>
          <p className="lede">{t('Keys are stored on the server and used for everyone’s chats and jobs. They can be replaced or removed here, but never read back.')}</p>
        </div>
        <button className="btn ghost" onClick={() => setAdding(true)} disabled={adding}>
          {t('Add provider')}
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
      {providers ? <VisionModelCard providers={providers} /> : null}
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
  const { t } = useI18n()
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
      return { ok: true, message: t('Provider saved.') }
    })

  const saveKey = () =>
    run('key', async () => {
      const ack = await api<Ack>(`providers/${status.provider.id}/key`, { method: 'POST', body: { key } })
      setKey('')
      onSaved()
      const test = await api<ProviderTestResult>(`providers/${status.provider.id}/test`, { method: 'POST' })
      return {
        ok: test.ok,
        message: test.ok
          ? `${ack.detail ?? t('Key saved')}. ${test.message}`
          : t('Key saved, but the test failed: {message}', { message: test.message }),
      }
    })

  return (
    <div className="card stack">
      <div className="row">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h2>{isNew ? t('New provider') : config.name}</h2>
          {!isNew ? (
            <div className="dim mono" style={{ fontSize: 11, overflowWrap: 'anywhere' }}>
              {config.id} · {config.kind === 'anthropic' ? 'Anthropic API' : 'OpenAI-compatible'} · {config.baseURL}
            </div>
          ) : null}
        </div>
        {!isNew ? <span className={status.hasKey ? 'chip em' : 'chip'}>{status.hasKey ? t('key saved') : t('no key')}</span> : null}
      </div>

      {editing ? (
        <div className="grid-3">
          <label className="field">
            <span>{t('Id')}</span>
            <input className="input" disabled={!isNew} value={config.id} onChange={(e) => setConfig({ ...config, id: e.target.value.toLowerCase() })} placeholder="my-provider" />
          </label>
          <label className="field">
            <span>{t('Name')}</span>
            <input className="input" value={config.name} onChange={(e) => setConfig({ ...config, name: e.target.value })} />
          </label>
          <label className="field">
            <span>{t('API style')}</span>
            <select className="select" value={config.kind} onChange={(e) => setConfig({ ...config, kind: e.target.value as ProviderConfig['kind'] })}>
              <option value="openAICompatible">OpenAI-compatible</option>
              <option value="anthropic">Anthropic</option>
            </select>
          </label>
          <label className="field" style={{ gridColumn: 'span 2' }}>
            <span>{t('Base URL')}</span>
            <input className="input" value={config.baseURL} onChange={(e) => setConfig({ ...config, baseURL: e.target.value })} />
          </label>
          <label className="field">
            <span>{t('Default model')}</span>
            <input className="input" value={config.defaultModel ?? ''} onChange={(e) => setConfig({ ...config, defaultModel: e.target.value })} />
          </label>
          <label className="field" style={{ gridColumn: '1 / -1' }}>
            <span>{t('Models (comma separated)')}</span>
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
            placeholder={status.hasKey ? t('Paste a new key to replace the saved one') : t('Paste API key')}
            value={key}
            onChange={(e) => setKey(e.target.value)}
            aria-label={t('API key for {name}', { name: config.name })}
          />
          <button className="btn small" disabled={!key.trim() || busy !== null} onClick={() => void saveKey()}>
            {busy === 'key' ? t('Saving…') : t('Save and test key')}
          </button>
          {status.hasKey ? (
            <button
              className="btn small ghost"
              disabled={busy !== null}
              onClick={() =>
                void run('test', async () => api<ProviderTestResult>(`providers/${status.provider.id}/test`, { method: 'POST' }))
              }
            >
              {busy === 'test' ? t('Testing…') : t('Test connection')}
            </button>
          ) : null}
        </div>
      ) : null}

      {result ? <div className={result.ok ? 'notice' : 'error'}>{result.message}</div> : null}

      <div className="row">
        {editing ? (
          <>
            <button className="btn small" disabled={busy !== null} onClick={() => void saveConfig()}>
              {t('Save provider')}
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
              {t('Cancel')}
            </button>
          </>
        ) : (
          <button className="pill" onClick={() => setEditing(true)}>
            {t('Edit models and URL')}
          </button>
        )}
        <span className="spacer" />
        {!isNew && status.hasKey ? (
          <button
            className="pill"
            onClick={() => {
              if (window.confirm(t('Remove the saved {name} key? Ada and her specialists can’t use {name} until you add a new one.', { name: config.name }))) {
                void run('remove', async () => {
                  await api(`providers/${status.provider.id}/key`, { method: 'DELETE' })
                  onSaved()
                  return { ok: true, message: t('Key removed.') }
                })
              }
            }}
          >
            {t('Remove key')}
          </button>
        ) : null}
        {!isNew ? (
          <button
            className="pill"
            onClick={() => {
              if (window.confirm(t('Delete the {name} provider and its key?', { name: config.name }))) {
                void run('delete', async () => {
                  await api(`providers/${status.provider.id}`, { method: 'DELETE' })
                  onSaved()
                })
              }
            }}
          >
            {t('Delete provider')}
          </button>
        ) : null}
      </div>
    </div>
  )
}

/** Which model looks at photos. Empty provider means automatic. */
export function VisionModelCard({ providers }: { providers: ProviderStatus[] }) {
  const { t } = useI18n()
  const [providerID, setProviderID] = useState('')
  const [model, setModel] = useState('')
  const [result, setResult] = useState<{ ok: boolean; message: string } | null>(null)

  useEffect(() => {
    api<{ setting?: VisionModelSetting | null }>('vision-model')
      .then((r) => {
        setProviderID(r.setting?.providerID ?? '')
        setModel(r.setting?.model ?? '')
      })
      .catch(() => undefined)
  }, [])

  const chosen = providers.find((p) => p.provider.id === providerID)
  const save = async () => {
    try {
      const setting = providerID ? { providerID, model: model.trim() } : null
      await api('vision-model', { method: 'PUT', body: { setting } })
      setResult({ ok: true, message: t('Vision model saved.') })
    } catch (err) {
      setResult({ ok: false, message: errorMessage(err) })
    }
  }

  return (
    <div className="card stack">
      <h2>{t('Vision model')}</h2>
      <p className="dim">{t("Used when a message has photos attached. Leave on automatic to use Ada's own model, or the image processor if hers cannot see.")}</p>
      <div className="grid-3">
        <label className="field">
          <span>{t('Provider')}</span>
          <select
            className="select"
            value={providerID}
            onChange={(e) => {
              setProviderID(e.target.value)
              setModel(providers.find((p) => p.provider.id === e.target.value)?.provider.defaultModel ?? '')
            }}
          >
            <option value="">{t('Automatic')}</option>
            {providers.filter((p) => p.hasKey).map((p) => (
              <option key={p.provider.id} value={p.provider.id}>{p.provider.name}</option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>{t('Model')}</span>
          <input className="input" list="vision-models" disabled={!providerID} value={model} onChange={(e) => setModel(e.target.value)} />
          <datalist id="vision-models">
            {(chosen?.provider.models ?? []).map((m) => <option key={m} value={m} />)}
          </datalist>
        </label>
      </div>
      {result ? <div className={result.ok ? 'notice' : 'error'}>{result.message}</div> : null}
      <div className="row">
        <button className="btn small" disabled={Boolean(providerID) && !model.trim()} onClick={() => void save()}>{t('Save vision model')}</button>
      </div>
    </div>
  )
}
