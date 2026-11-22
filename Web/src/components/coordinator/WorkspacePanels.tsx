import { useEffect, useState } from 'react'
import { api, errorMessage } from '../../api/client'
import type { AccessAuditEntry, ConnectorPermissions, ConnectorStatus, HostFolderGrant, WorkspaceKnowledge, WorkspaceKnowledgeDocumentID, WorkspaceMemory } from '../../api/types'
import { useAuth } from '../../auth/AuthContext'
import { dateLocale, useI18n } from '../../i18n'
import { ErrorBanner } from '../ui'
import { Icon } from './Icon'

export function Switch({ checked, label, onChange, disabled = false }: { checked: boolean; label: string; onChange: () => void; disabled?: boolean }) {
  return <button type="button" className="co-switch" role="switch" aria-checked={checked} aria-label={label} disabled={disabled} onClick={onChange} />
}

export function ConnectorCard({ connector, onChange }: { connector: ConnectorStatus; onChange: (connector: ConnectorStatus) => void }) {
  const { t } = useI18n()
  const { isAdmin } = useAuth()
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [secret, setSecret] = useState('')
  const [customerID, setCustomerID] = useState('')
  const google = connector.id === 'gmail' || connector.id === 'googleads'
  const patch = async (body: { enabled?: boolean; permissions?: ConnectorPermissions }) => {
    setBusy(true); setError(null)
    try { onChange(await api<ConnectorStatus>(`connectors/${connector.id}`, { method: 'PATCH', body })) } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const permission = (name: keyof ConnectorPermissions, value: boolean) => void patch({ permissions: { ...connector.permissions, [name]: value } })
  const connect = async () => {
    setBusy(true); setError(null)
    try {
      const result = await api<{ url: string }>(`connectors/${connector.id}/authorize`, { method: 'POST', body: { clientKind: 'browser' } })
      const url = new URL(result.url)
      if (url.protocol !== 'https:') throw new Error(t('The server returned an invalid authorization URL.'))
      window.location.assign(url.toString())
    } catch (err) { setError(errorMessage(err)); setBusy(false) }
  }
  const test = async () => {
    setBusy(true); setMessage(null); setError(null)
    try {
      const result = await api<{ ok: boolean; message: string }>(`connectors/${connector.id}/test`, { method: 'POST' })
      setMessage(result.message)
      if (!result.ok) setError(result.message)
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const saveCredentials = async () => {
    setBusy(true); setError(null); setMessage(null)
    try {
      if (connector.id === 'cloudflare' || connector.id === 'github') await api(`connectors/${connector.id}/token`, { method: 'POST', body: { key: secret } })
      if (connector.id === 'googleads') await api(`connectors/googleads/credentials`, { method: 'POST', body: { developerToken: secret, customerId: customerID } })
      setSecret(''); setCustomerID('')
      onChange(await api<ConnectorStatus>(`connectors/${connector.id}`))
      setMessage(t('Credentials saved.'))
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  return <article className="co-connector-card"><div className="co-connector-head"><span className={`co-connector-logo ${connector.id}`}>{connector.name[0]}</span><div><b>{connector.name}</b><small>{connector.configured ? t('Connected') : t('Not connected')}</small></div><Switch checked={connector.enabled} label={t('Enable {name}', { name: connector.name })} disabled={busy || !isAdmin} onChange={() => void patch({ enabled: !connector.enabled })} /></div>
    <p className="co-connector-detail">{connector.detail}</p>
    {connector.id === 'gmail' ? <div className="co-permission-row"><div><b>{t('Read your inbox')}</b><small>{t('Ada can search and read messages in chat.')}</small></div><span className="co-chip">{t('Read only')}</span></div> : null}
    {connector.id === 'gmail' ? <><div className="co-permission-row"><div><b>{t('Create drafts')}</b><small>{t('Allow Ada and her specialists to prepare drafts, never auto-send.')}</small></div><Switch checked={connector.permissions.createDraft} label={t('Allow Gmail drafts')} disabled={busy || !isAdmin} onChange={() => permission('createDraft', !connector.permissions.createDraft)} /></div><div className="co-permission-row"><div><b>{t('Send email')}</b><small>{t('Allow Ada and her specialists to send when you explicitly request it.')}</small></div><Switch checked={connector.permissions.sendEmail} label={t('Allow Gmail sending')} disabled={busy || !isAdmin} onChange={() => permission('sendEmail', !connector.permissions.sendEmail)} /></div></> : null}
    {connector.id === 'github' ? <div className="co-permission-row"><div><b>{t('Read repositories')}</b><small>{t('Agents can always read code, issues, and pull requests.')}</small></div><span className="co-chip">{t('Read only')}</span></div> : null}
    {connector.id === 'github' ? <div className="co-permission-row"><div><b>{t('GitHub writes')}</b><small>{t('Allow Ada and her specialists to commit to a working branch (never the default branch) and comment.')}</small></div><Switch checked={connector.permissions.githubWrite} label={t('Allow GitHub writes')} disabled={busy || !isAdmin} onChange={() => permission('githubWrite', !connector.permissions.githubWrite)} /></div> : null}
    {connector.id === 'cloudflare' ? <div className="co-permission-row"><div><b>{t('DNS writes')}</b><small>{t('Allow Ada and her specialists to change DNS or purge cache.')}</small></div><Switch checked={connector.permissions.dnsWrite} label={t('Allow DNS writes')} disabled={busy || !isAdmin} onChange={() => permission('dnsWrite', !connector.permissions.dnsWrite)} /></div> : null}
    {connector.id === 'googleads' ? <div className="co-permission-row"><div><b>{t('Google Ads changes')}</b><small>{t('Allow Ada and her specialists to change campaigns, budgets, ad groups, ads and assets. You approve each change before it runs.')}</small></div><Switch checked={connector.permissions.adsWrite ?? false} label={t('Allow Google Ads changes')} disabled={busy || !isAdmin} onChange={() => permission('adsWrite', !(connector.permissions.adsWrite ?? false))} /></div> : null}
    {isAdmin && google ? <button className="co-secondary-button co-full-button" disabled={busy || !connector.oauthAvailable} title={!connector.oauthAvailable ? t('Google OAuth needs to be configured on the server.') : undefined} onClick={() => void connect()}><Icon name="plug" size={13} />{connector.configured ? t('Reconnect {name}', { name: connector.name }) : t('Connect {name}', { name: connector.name })}</button> : null}
    {isAdmin && google && !connector.oauthAvailable ? <p className="co-field-hint">{t('Google OAuth needs to be configured on the server.')}</p> : null}
    {isAdmin && (connector.id === 'cloudflare' || connector.id === 'github') ? <form className="co-credential-form" onSubmit={(event) => { event.preventDefault(); void saveCredentials() }}><label className="field"><span>{connector.id === 'github' ? t('GitHub token') : t('Cloudflare API token')}</span><input className="input" type="password" autoComplete="off" value={secret} onChange={(event) => setSecret(event.target.value)} placeholder={connector.configured ? t('Replace saved token') : t('Paste API token')} required /></label><button className="co-secondary-button" disabled={busy || !secret.trim()}>{t('Save token')}</button></form> : null}
    {isAdmin && connector.id === 'googleads' ? <form className="co-credential-form" onSubmit={(event) => { event.preventDefault(); void saveCredentials() }}><label className="field"><span>{t('Developer token')}</span><input className="input" type="password" autoComplete="off" value={secret} onChange={(event) => setSecret(event.target.value)} placeholder={t('Optional if already saved')} /></label><label className="field"><span>{t('Customer ID')}</span><input className="input" value={customerID} onChange={(event) => setCustomerID(event.target.value)} placeholder="1234567890" /></label><button className="co-secondary-button" disabled={busy || (!secret.trim() && !customerID.trim())}>{t('Save credentials')}</button></form> : null}
    {isAdmin ? <div className="co-connector-actions"><button className="co-text-button" disabled={busy || !connector.configured} onClick={() => void test()}>{busy ? t('Testing…') : t('Test connection')}</button>{connector.configured ? <button className="co-text-button danger" disabled={busy} onClick={() => {
      if (!window.confirm(t('Disconnect {name}? Ada will lose access.', { name: connector.name }))) return
      setBusy(true)
      void api(`connectors/${connector.id}/disconnect`, { method: 'POST' }).then(async () => onChange(await api<ConnectorStatus>(`connectors/${connector.id}`))).catch((err) => setError(errorMessage(err))).finally(() => setBusy(false))
    }}>{t('Disconnect')}</button> : null}</div> : null}
    {message ? <p className="co-success" role="status">{message}</p> : null}<ErrorBanner message={error} />
  </article>
}

export function KnowledgePanel({ knowledge, onChange }: { knowledge: WorkspaceKnowledge | null; onChange: (knowledge: WorkspaceKnowledge) => void }) {
  const { t } = useI18n()
  const [selected, setSelected] = useState<WorkspaceKnowledgeDocumentID>('capabilities')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const document = knowledge?.documents.find((item) => item.id === selected) ?? knowledge?.documents[0]
  const refresh = async () => {
    if (busy) return
    setBusy(true); setError(null)
    try { onChange(await api<WorkspaceKnowledge>('workspace/knowledge/refresh', { method: 'POST' })) } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  return <section><div className="co-setting-card"><div className="co-knowledge-toolbar"><div><b>{t('Workspace knowledge')}</b><div className="co-memory-meta">{knowledge?.updatedAt ? `${t('{count} refreshes', { count: knowledge.refreshCount })} · ${new Date(knowledge.updatedAt).toLocaleString(dateLocale())}` : t('Discovering your workspace…')}</div></div><button className="co-secondary-button" disabled={busy} onClick={() => void refresh()}><Icon name="refresh" size={14} />{busy ? t('Refreshing…') : t('Refresh now')}</button></div>
    <p className="co-panel-note">{t('Built from live skills, providers, tools, connections, and projects. Refreshed on first launch, when changes are detected, and at least daily. No credentials or connected content are included.')}</p>
    <div className="co-knowledge-tabs" aria-label={t('Knowledge documents')}>{knowledge?.documents.map((item) => <button key={item.id} className={document?.id === item.id ? 'active' : ''} aria-pressed={document?.id === item.id} onClick={() => setSelected(item.id)}>{item.id === 'capabilities' ? t('Capabilities') : item.id === 'connections' ? t('Connections') : t('Projects')}</button>)}</div>
    <pre className="co-memory-doc">{document?.markdown ?? t('Discovering your workspace…')}</pre>
    {document ? <a className="co-secondary-button co-download" href={`/api/workspace/knowledge/${document.id}/export`} download><Icon name="download" size={14} />{t('Export {name}.md', { name: document.id })}</a> : null}
    <ErrorBanner message={error ?? knowledge?.lastError ?? null} /></div></section>
}

export function MemoryPanel({ memory, onChange }: { memory: WorkspaceMemory | null; onChange: (memory: WorkspaceMemory) => void }) {
  const { t } = useI18n()
  const [error, setError] = useState<string | null>(null)
  const toggle = async () => {
    if (!memory) return
    try { onChange(await api<WorkspaceMemory>('workspace/memory', { method: 'PATCH', body: { enabled: !memory.enabled } })); setError(null) } catch (err) { setError(errorMessage(err)) }
  }
  return <section><div className="co-setting-card"><div className="co-setting-row"><div><b>{t('Workspace memory')}</b><p>{t('A continuously compacted Markdown summary shared across your chats.')}</p></div><Switch checked={memory?.enabled ?? false} label={t('Workspace memory enabled')} onChange={() => void toggle()} /></div><div className="co-memory-meta">{memory ? `${t('{count} compactions', { count: memory.compactionCount })} · ${t('{count} source exchanges', { count: memory.sources.length })}${memory.pendingEntries ? ` · ${t('{count} pending', { count: memory.pendingEntries })}` : ''}` : t('Loading')}</div><p className="co-panel-note">{t('Pausing stops new memories from being recorded. It does not delete the existing summary. Memory contains concise facts, not private reasoning.')}</p><pre className="co-memory-doc">{memory?.markdown ?? t('Loading')}</pre><a className="co-secondary-button co-download" href="/api/workspace/memory/export" download><Icon name="file" size={14} />{t('Export memory.md')}</a><ErrorBanner message={error} /></div></section>
}

export function HostAccessPanel() {
  const { t } = useI18n()
  const { isAdmin } = useAuth()
  const [grants, setGrants] = useState<HostFolderGrant[]>([])
  const [audit, setAudit] = useState<AccessAuditEntry[]>([])
  const [path, setPath] = useState('')
  const [canWrite, setCanWrite] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const refresh = async () => {
    if (!isAdmin) return
    try {
      const [nextGrants, entries] = await Promise.all([api<HostFolderGrant[]>('access/host-grants'), api<AccessAuditEntry[]>('access/audit')])
      setGrants(nextGrants); setAudit(entries); setError(null)
    } catch (err) { setError(errorMessage(err)) }
  }
  useEffect(() => { void refresh() }, [isAdmin])
  const grant = async () => {
    setBusy(true); setError(null)
    try {
      await api<HostFolderGrant>('access/host-grants', { method: 'POST', body: { path, canWrite } })
      setPath(''); setCanWrite(false); await refresh()
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const revoke = async (id: string) => {
    if (!window.confirm(t('Revoke Ada’s access to this folder? Existing files are unchanged.'))) return
    setBusy(true)
    try { await api(`access/host-grants/${id}`, { method: 'DELETE' }); await refresh() } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  if (!isAdmin) return null
  return <div className="co-setting-card co-host-access"><h3>{t('Host folder access')}</h3>
    <p className="co-panel-note">{t('Grant a specific folder on the server, not your whole home folder. Ada can list and read its text files. Writes require read/write access; there is no host shell access.')}</p>
    <form onSubmit={(event) => { event.preventDefault(); void grant() }}>
      <label className="field"><span>{t('Absolute server folder path')}</span><input className="input" value={path} onChange={(event) => setPath(event.target.value)} placeholder="/srv/my-project" required /></label>
      <label className="co-host-write"><input type="checkbox" checked={canWrite} onChange={(event) => setCanWrite(event.target.checked)} /><span>{t('Allow Ada to write text files in this folder')}</span></label>
      <button className="co-secondary-button" disabled={busy || !path.trim()}><Icon name="folder" size={13} />{t('Grant folder access')}</button>
    </form>
    {grants.map((item) => <div className="co-permission-row" key={item.id}><div><b>{item.path}</b><small>{item.canWrite ? t('Read/write') : t('Read only')}</small></div><button className="co-text-button danger" disabled={busy} onClick={() => void revoke(item.id)}>{t('Revoke')}</button></div>)}
    {audit.length ? <details className="co-access-audit"><summary>{t('Recent access activity')}</summary><ul>{audit.slice(0, 8).map((entry) => <li key={entry.id}><code>{entry.action}</code><span>{entry.detail}</span><time>{new Date(entry.timestamp).toLocaleString(dateLocale())}</time></li>)}</ul></details> : null}
    <ErrorBanner message={error} />
  </div>
}
