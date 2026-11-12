import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import type { Ack, BatchDetail, ProvisioningDelivery, ProvisioningItem, PublicBatch, UserRole } from '../api/types'
import { ErrorBanner, Field, formatDate, Spinner } from '../components/ui'
import { useI18n } from '../i18n'
import { useDocumentTitle } from '../lib/useDocumentTitle'

const suggestedDomains = ['example.com', 'example.net', 'example.org']
const pacePresets = {
  careful: { lowerBound: 120, upperBound: 300 },
  standard: { lowerBound: 30, upperBound: 120 },
  fast: { lowerBound: 5, upperBound: 15 },
} as const

type PacePreset = keyof typeof pacePresets

function active(batch: PublicBatch): boolean {
  return batch.status === 'queued' || batch.status === 'running' || batch.items.some((item) => item.state === 'creating')
}

function credentialValue(item: ProvisioningItem): string | null {
  if (!item.secret) return null
  return item.secret.startsWith('/invite#') ? `${window.location.origin}${item.secret}` : item.secret
}

function csvCell(value: string): string {
  return `"${value.replaceAll('"', '""')}"`
}

export function ProvisioningPage() {
  const { t } = useI18n()
  useDocumentTitle(t('Bulk provisioning'))

  const [batches, setBatches] = useState<PublicBatch[] | null>(null)
  const [selectedID, setSelectedID] = useState<string | null>(null)
  const [detail, setDetail] = useState<BatchDetail | null>(null)
  const [refreshVersion, setRefreshVersion] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [creating, setCreating] = useState(false)
  const [copiedID, setCopiedID] = useState<string | null>(null)

  const [count, setCount] = useState(5)
  const [role, setRole] = useState<UserRole>('member')
  const [confirmAdmin, setConfirmAdmin] = useState(false)
  const [delivery, setDelivery] = useState<ProvisioningDelivery>('inviteLinks')
  const [domains, setDomains] = useState<string[]>(suggestedDomains)
  const [customDomains, setCustomDomains] = useState('')
  const [pace, setPace] = useState<PacePreset>('standard')
  const [expiresInDays, setExpiresInDays] = useState(7)

  const loadBatches = useCallback(async () => {
    try {
      const next = await api<PublicBatch[]>('admin/provisioning/batches')
      setBatches(next)
      setSelectedID((current) => (current && next.some((batch) => batch.id === current) ? current : (next[0]?.id ?? null)))
      setError(null)
    } catch (err) {
      setError(errorMessage(err))
    }
  }, [])

  useEffect(() => {
    void loadBatches()
  }, [loadBatches])

  const hasActiveBatches = batches?.some(active) ?? false
  useEffect(() => {
    if (!hasActiveBatches) return
    const timer = window.setTimeout(() => void loadBatches(), 3_000)
    return () => window.clearTimeout(timer)
  }, [hasActiveBatches, batches, loadBatches])

  useEffect(() => {
    if (!selectedID) {
      setDetail(null)
      return
    }
    let cancelled = false
    let timer: number | undefined

    async function poll(id: string) {
      try {
        const next = await api<BatchDetail>(`admin/provisioning/batches/${id}`)
        if (cancelled) return
        setDetail(next)
        setError(null)
        if (active(next.batch)) timer = window.setTimeout(() => void poll(id), 3_000)
      } catch (err) {
        if (!cancelled) setError(errorMessage(err))
      }
    }

    setDetail(null)
    void poll(selectedID)
    return () => {
      cancelled = true
      if (timer !== undefined) window.clearTimeout(timer)
    }
  }, [selectedID, refreshVersion])

  const customDomainList = useMemo(
    () =>
      customDomains
        .split(/[\s,]+/)
        .map((domain) => domain.trim().toLowerCase())
        .filter(Boolean),
    [customDomains],
  )
  const selectedBatch = detail?.batch ?? batches?.find((batch) => batch.id === selectedID) ?? null
  const revealableItems = detail?.batch.items.filter((item) => item.secret) ?? []

  async function run(action: () => Promise<unknown>) {
    setBusy(true)
    setError(null)
    try {
      await action()
      await loadBatches()
      setRefreshVersion((version) => version + 1)
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  async function createBatch(event: FormEvent) {
    event.preventDefault()
    const allDomains = [...new Set([...domains, ...customDomainList])]
    if (allDomains.length === 0) {
      setError(t('Select or enter at least one domain.'))
      return
    }
    if (role === 'admin' && !confirmAdmin) {
      setError(t('Confirm that this batch creates admin accounts.'))
      return
    }
    setCreating(true)
    setError(null)
    try {
      const range = pacePresets[pace]
      const created = await api<PublicBatch>('admin/provisioning/batches', {
        method: 'POST',
        body: {
          count,
          role,
          domains: allDomains,
          delivery,
          paceSeconds: [range.lowerBound, range.upperBound],
          expiresInDays: delivery === 'inviteLinks' ? expiresInDays : undefined,
          confirmRole: role === 'admin' ? 'admin' : undefined,
        },
      })
      setSelectedID(created.id)
      setDetail({ batch: created })
      await loadBatches()
      setRefreshVersion((version) => version + 1)
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setCreating(false)
    }
  }

  function batchAction(id: string, action: string) {
    void run(() => api<PublicBatch>(`admin/provisioning/batches/${id}/${action}`, { method: 'POST' }))
  }

  function cancelBatch(id: string) {
    if (!window.confirm(t('Cancel the remaining items? Accounts and invites already created will remain.'))) return
    void run(() => api<Ack>(`admin/provisioning/batches/${id}`, { method: 'DELETE' }))
  }

  function removeSecretsFromView(itemIDs: string[]) {
    const acknowledged = new Set(itemIDs)
    setDetail((current) =>
      current
        ? {
            batch: {
              ...current.batch,
              items: current.batch.items.map((item) =>
                acknowledged.has(item.id) ? { ...item, secret: undefined, secretAcknowledged: true } : item,
              ),
            },
          }
        : current,
    )
  }

  async function acknowledge(itemIDs: string[]) {
    if (!selectedID || itemIDs.length === 0) return
    await api<Ack>(`admin/provisioning/batches/${selectedID}/ack`, { method: 'POST', body: { itemIDs } })
    removeSecretsFromView(itemIDs)
  }

  async function copyCredential(item: ProvisioningItem) {
    const credential = credentialValue(item)
    if (!credential) return
    setError(null)
    try {
      await navigator.clipboard.writeText(credential)
      await acknowledge([item.id])
      setCopiedID(item.id)
      window.setTimeout(() => setCopiedID((current) => (current === item.id ? null : current)), 2_000)
    } catch (err) {
      setError(errorMessage(err))
    }
  }

  async function downloadCSV() {
    if (!detail || revealableItems.length === 0) return
    if (!window.confirm(t('Download credentials and permanently hide them from this page? Store the CSV securely.'))) return
    setBusy(true)
    setError(null)
    try {
      const rows = revealableItems.map((item) => [item.email ?? '', credentialValue(item) ?? ''])
      const csv = ['email,password_or_invite_link', ...rows.map((row) => row.map(csvCell).join(','))].join('\r\n')
      const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }))
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = `agentsam-provisioning-${detail.batch.id}.csv`
      document.body.appendChild(anchor)
      anchor.click()
      anchor.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 1_000)
      await acknowledge(revealableItems.map((item) => item.id))
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">{t('People')}</div>
          <h1>{t('Bulk account provisioning')}</h1>
          <p className="lede">{t('Create identity-separated accounts with independent credentials, domains, names, and jittered creation times.')}</p>
        </div>
        <Link className="btn ghost" to="/people">
          {t('Back to people')}
        </Link>
      </div>

      <div className="notice" style={{ marginBottom: 18 }}>
        {t('Identity separation only: every account still shares the same teams and missions. Credentials are retrievable until copied or downloaded, then permanently hidden.')}
      </div>
      <ErrorBanner message={error} />

      <form className="card stack" onSubmit={createBatch} style={{ marginTop: error ? 14 : 0 }}>
        <h2>{t('New batch')}</h2>
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <Field label={t('Accounts')} type="number" min={1} max={50} required value={count} onChange={(event) => setCount(event.target.valueAsNumber)} hint={t('1–50 per batch; server limits may be lower.')} />
          <label className="field">
            <span>{t('Role')}</span>
            <select
              className="select"
              value={role}
              onChange={(event) => {
                setRole(event.target.value as UserRole)
                setConfirmAdmin(false)
              }}
            >
              <option value="member">{t('Member')}</option>
              <option value="admin">{t('Admin')}</option>
            </select>
          </label>
          <label className="field" style={{ flex: '1 1 260px' }}>
            <span>{t('Delivery')}</span>
            <select className="select" value={delivery} onChange={(event) => setDelivery(event.target.value as ProvisioningDelivery)}>
              <option value="inviteLinks">{t('Single-use invite links')}</option>
              <option value="directPasswords">{t('Generated passwords')}</option>
            </select>
          </label>
          <label className="field">
            <span>{t('Pacing')}</span>
            <select className="select" value={pace} onChange={(event) => setPace(event.target.value as PacePreset)}>
              <option value="careful">{t('Careful · 120–300 seconds')}</option>
              <option value="standard">{t('Standard · 30–120 seconds')}</option>
              <option value="fast">{t('Fast · 5–15 seconds')}</option>
            </select>
          </label>
          {delivery === 'inviteLinks' ? (
            <Field label={t('Invite expiry (days)')} type="number" min={1} max={365} required value={expiresInDays} onChange={(event) => setExpiresInDays(event.target.valueAsNumber)} />
          ) : null}
        </div>

        <fieldset className="stack" style={{ border: 0 }}>
          <legend className="muted">{t('Domain pool · a random domain is chosen for each account')}</legend>
          <div className="row">
            {suggestedDomains.map((domain) => (
              <label className="row" key={domain} style={{ flexWrap: 'nowrap' }}>
                <input
                  type="checkbox"
                  checked={domains.includes(domain)}
                  onChange={() => setDomains((current) => (current.includes(domain) ? current.filter((value) => value !== domain) : [...current, domain]))}
                />
                <span className="mono">{domain}</span>
              </label>
            ))}
          </div>
          <label className="field">
            <span>{t('Additional domains (optional)')}</span>
            <input className="input" value={customDomains} onChange={(event) => setCustomDomains(event.target.value)} placeholder="mail.example.com, accounts.example.net" />
            <small className="hint">{t('Comma-separated. Use domains you control; the reserved example domains are suitable for local testing.')}</small>
          </label>
        </fieldset>

        {role === 'admin' ? (
          <label className="row" style={{ flexWrap: 'nowrap' }}>
            <input type="checkbox" checked={confirmAdmin} onChange={(event) => setConfirmAdmin(event.target.checked)} />
            <span>{t('I confirm that every account in this batch will have admin privileges.')}</span>
          </label>
        ) : null}

        <div className="row">
          <button className="btn" type="submit" disabled={creating || !Number.isInteger(count) || count < 1 || count > 50}>
            {creating ? t('Creating batch…') : t('Create batch')}
          </button>
          <span className="dim">{t('Items run one at a time. A failed item does not block the rest.')}</span>
        </div>
      </form>

      <section className="card">
        <h2 style={{ marginBottom: 12 }}>{t('Batches')}</h2>
        {!batches ? (
          <Spinner />
        ) : batches.length === 0 ? (
          <div className="empty">{t('No provisioning batches yet.')}</div>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>{t('Batch')}</th>
                  <th>{t('Created')}</th>
                  <th>{t('Configuration')}</th>
                  <th>{t('Status')}</th>
                  <th>{t('Progress')}</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {batches.map((batch) => {
                  const done = batch.items.filter((item) => item.state === 'done').length
                  const failed = batch.items.filter((item) => item.state === 'failed').length
                  return (
                    <tr key={batch.id}>
                      <td>
                        <button className="btn small ghost" onClick={() => setSelectedID(batch.id)} aria-pressed={selectedID === batch.id}>
                          {batch.id.slice(0, 8)}
                        </button>
                      </td>
                      <td className="dim">{formatDate(batch.createdAt)}</td>
                      <td>
                        {t(batch.spec.role)} · {batch.spec.delivery === 'inviteLinks' ? t('Invites') : t('Passwords')}
                        <div className="dim">{batch.spec.domains.length} {t('domains')}</div>
                      </td>
                      <td>
                        <span className={`chip ${batch.status === 'running' || batch.status === 'done' ? 'em' : batch.status === 'cancelled' ? 'danger' : ''}`}>{t(batch.status)}</span>
                      </td>
                      <td>
                        {done}/{batch.items.length}
                        {failed ? <span className="chip danger" style={{ marginLeft: 6 }}>{failed} {t('failed')}</span> : null}
                      </td>
                      <td>
                        <div className="row" style={{ justifyContent: 'flex-end' }}>
                          {batch.status === 'queued' || batch.status === 'running' ? (
                            <button className="btn small ghost" disabled={busy} onClick={() => batchAction(batch.id, 'pause')}>{t('Pause')}</button>
                          ) : null}
                          {batch.status === 'paused' ? (
                            <button className="btn small ghost" disabled={busy} onClick={() => batchAction(batch.id, 'resume')}>{t('Resume')}</button>
                          ) : null}
                          {failed > 0 && batch.status !== 'cancelled' ? (
                            <button className="btn small ghost" disabled={busy} onClick={() => batchAction(batch.id, 'retry-failed')}>{t('Retry failed')}</button>
                          ) : null}
                          {batch.status !== 'done' && batch.status !== 'cancelled' ? (
                            <button className="btn small danger" disabled={busy} onClick={() => cancelBatch(batch.id)}>{t('Cancel')}</button>
                          ) : null}
                        </div>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {selectedID ? (
        <section className="card stack">
          <div className="row">
            <div>
              <h2>{t('Batch items')}</h2>
              <span className="dim mono">{selectedID}</span>
            </div>
            <div className="spacer" />
            <button className="btn small gold" disabled={busy || revealableItems.length === 0} onClick={() => void downloadCSV()}>
              {t('Download CSV')} ({revealableItems.length})
            </button>
          </div>
          {revealableItems.length > 0 ? (
            <div className="notice">{t('Copy or download credentials now. Each copy or download acknowledges those items and removes their secrets from the server.')}</div>
          ) : null}
          {!detail || detail.batch.id !== selectedID ? (
            <Spinner />
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>{t('State')}</th>
                    <th>{t('Email')}</th>
                    <th>{t('Attempts')}</th>
                    <th>{t('Completed')}</th>
                    <th>{t('Error')}</th>
                    <th>{t('Credential')}</th>
                  </tr>
                </thead>
                <tbody>
                  {detail.batch.items.map((item) => {
                    const credential = credentialValue(item)
                    return (
                      <tr key={item.id}>
                        <td><span className={`chip ${item.state === 'failed' ? 'danger' : item.state === 'done' ? 'em' : ''}`}>{t(item.state)}</span></td>
                        <td className="muted">{item.email ?? '—'}</td>
                        <td>{item.attemptCount}</td>
                        <td className="dim">{formatDate(item.completedAt)}</td>
                        <td className={item.lastError ? 'danger' : 'dim'}>{item.lastError ?? '—'}</td>
                        <td>
                          {credential ? (
                            <div className="stack" style={{ gap: 6 }}>
                              <code className="mono" style={{ wordBreak: 'break-all' }}>{credential}</code>
                              <button className="btn small ghost" onClick={() => void copyCredential(item)}>
                                {copiedID === item.id ? t('Copied') : t('Copy and hide')}
                              </button>
                            </div>
                          ) : item.secretAcknowledged ? (
                            <span className="dim">{t('Acknowledged')}</span>
                          ) : item.state === 'done' ? (
                            <span className="dim">{t('Unavailable')}</span>
                          ) : '—'}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
          {selectedBatch && selectedBatch.status === 'paused' ? <div className="notice">{t('This batch is paused. Resume it to create the remaining items.')}</div> : null}
        </section>
      ) : null}
    </>
  )
}
