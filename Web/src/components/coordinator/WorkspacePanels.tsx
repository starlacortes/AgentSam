import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../../api/client'
import type { ConnectorPermissions, ConnectorStatus, Team, WorkspaceMemory } from '../../api/types'
import { useAuth } from '../../auth/AuthContext'
import { useI18n } from '../../i18n'
import { LanguageToggle } from '../Layout'
import { ErrorBanner } from '../ui'
import { Drawer } from './Overlay'
import { Icon } from './Icon'
import type { PanelName } from './CoordinatorSidebar'

function Switch({ checked, label, onChange, disabled = false }: { checked: boolean; label: string; onChange: () => void; disabled?: boolean }) {
  return <button type="button" className="co-switch" role="switch" aria-checked={checked} aria-label={label} disabled={disabled} onClick={onChange} />
}

function TeamsPanel({ teams, onNewTeam }: { teams: Team[]; onNewTeam: () => void }) {
  const { t } = useI18n()
  return <section><div className="co-section-heading"><h3>{t('Your teams')}</h3><span>{teams.length}</span></div><p className="co-panel-note">{t('Ada chooses the smallest team that fits. Ask in chat to create or change a roster.')}</p>
    {teams.map((team) => <article className="co-team-card" key={team.id}><div className="co-team-card-head"><span className="co-team-emoji">{team.emoji}</span><div><b>{team.name}</b><small>{t('{count} agents', { count: team.agents.length })}</small></div></div><p>{team.goal || t('A specialist team for your workspace.')}</p><div className="co-avatar-stack">{team.agents.map((agent) => <span className="co-tiny-avatar" key={agent.id} title={`${agent.name} · ${agent.title}`}>{agent.name[0]}</span>)}</div><div className="co-team-actions"><Link to={`/teams/${team.id}`}>{t('Edit team')} →</Link></div></article>)}
    <div className="co-panel-actions"><button className="co-primary-button" onClick={onNewTeam}><Icon name="spark" size={14} />{t('Design a team with Ada')}</button><Link className="co-secondary-button" to="/teams/new">{t('Create manually')}</Link><Link className="co-secondary-button" to="/templates">{t('Browse templates')}</Link></div>
  </section>
}

function ConnectorCard({ connector, onChange }: { connector: ConnectorStatus; onChange: (connector: ConnectorStatus) => void }) {
  const { t } = useI18n()
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
      if (connector.id === 'cloudflare') await api(`connectors/cloudflare/token`, { method: 'POST', body: { key: secret } })
      if (connector.id === 'googleads') await api(`connectors/googleads/credentials`, { method: 'POST', body: { developerToken: secret, customerId: customerID } })
      setSecret(''); setCustomerID('')
      onChange(await api<ConnectorStatus>(`connectors/${connector.id}`))
      setMessage(t('Credentials saved.'))
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  return <article className="co-connector-card"><div className="co-connector-head"><span className={`co-connector-logo ${connector.id}`}>{connector.name[0]}</span><div><b>{connector.name}</b><small>{connector.configured ? t('Connected') : t('Not connected')}</small></div><Switch checked={connector.enabled} label={t('Enable {name}', { name: connector.name })} disabled={busy} onChange={() => void patch({ enabled: !connector.enabled })} /></div>
    <p className="co-connector-detail">{connector.detail}</p>
    {connector.id === 'gmail' ? <div className="co-permission-row"><div><b>{t('Read your inbox')}</b><small>{t('Ada can search and read messages in chat.')}</small></div><span className="co-chip">{t('Read only')}</span></div> : null}
    {connector.id === 'gmail' ? <><div className="co-permission-row"><div><b>{t('Create drafts')}</b><small>{t('Allow team workers to prepare drafts, never auto-send.')}</small></div><Switch checked={connector.permissions.createDraft} label={t('Allow Gmail drafts')} disabled={busy} onChange={() => permission('createDraft', !connector.permissions.createDraft)} /></div><div className="co-permission-row"><div><b>{t('Send email')}</b><small>{t('Allow team workers to send when you explicitly request it.')}</small></div><Switch checked={connector.permissions.sendEmail} label={t('Allow Gmail sending')} disabled={busy} onChange={() => permission('sendEmail', !connector.permissions.sendEmail)} /></div></> : null}
    {connector.id === 'cloudflare' ? <div className="co-permission-row"><div><b>{t('DNS writes')}</b><small>{t('Allow team workers to change DNS or purge cache.')}</small></div><Switch checked={connector.permissions.dnsWrite} label={t('Allow DNS writes')} disabled={busy} onChange={() => permission('dnsWrite', !connector.permissions.dnsWrite)} /></div> : null}
    {google ? <button className="co-secondary-button co-full-button" disabled={busy || !connector.oauthAvailable} title={!connector.oauthAvailable ? t('Google OAuth needs to be configured on the server.') : undefined} onClick={() => void connect()}><Icon name="plug" size={13} />{connector.configured ? t('Reconnect {name}', { name: connector.name }) : t('Connect {name}', { name: connector.name })}</button> : null}
    {google && !connector.oauthAvailable ? <p className="co-field-hint">{t('Google OAuth needs to be configured on the server.')}</p> : null}
    {connector.id === 'cloudflare' ? <form className="co-credential-form" onSubmit={(event) => { event.preventDefault(); void saveCredentials() }}><label className="field"><span>{t('Cloudflare API token')}</span><input className="input" type="password" autoComplete="off" value={secret} onChange={(event) => setSecret(event.target.value)} placeholder={connector.configured ? t('Replace saved token') : t('Paste API token')} required /></label><button className="co-secondary-button" disabled={busy || !secret.trim()}>{t('Save token')}</button></form> : null}
    {connector.id === 'googleads' ? <form className="co-credential-form" onSubmit={(event) => { event.preventDefault(); void saveCredentials() }}><label className="field"><span>{t('Developer token')}</span><input className="input" type="password" autoComplete="off" value={secret} onChange={(event) => setSecret(event.target.value)} placeholder={t('Optional if already saved')} /></label><label className="field"><span>{t('Customer ID')}</span><input className="input" value={customerID} onChange={(event) => setCustomerID(event.target.value)} placeholder="1234567890" /></label><button className="co-secondary-button" disabled={busy || (!secret.trim() && !customerID.trim())}>{t('Save credentials')}</button></form> : null}
    <div className="co-connector-actions"><button className="co-text-button" disabled={busy || !connector.configured} onClick={() => void test()}>{busy ? t('Testing…') : t('Test connection')}</button>{connector.configured ? <button className="co-text-button danger" disabled={busy} onClick={() => {
      if (!window.confirm(t('Disconnect {name}? Ada and your teams will lose access.', { name: connector.name }))) return
      setBusy(true)
      void api(`connectors/${connector.id}/disconnect`, { method: 'POST' }).then(async () => onChange(await api<ConnectorStatus>(`connectors/${connector.id}`))).catch((err) => setError(errorMessage(err))).finally(() => setBusy(false))
    }}>{t('Disconnect')}</button> : null}</div>
    {message ? <p className="co-success" role="status">{message}</p> : null}<ErrorBanner message={error} />
  </article>
}

function MemoryPanel({ memory, onChange }: { memory: WorkspaceMemory | null; onChange: (memory: WorkspaceMemory) => void }) {
  const { t } = useI18n()
  const [error, setError] = useState<string | null>(null)
  const toggle = async () => {
    if (!memory) return
    try { onChange(await api<WorkspaceMemory>('workspace/memory', { method: 'PATCH', body: { enabled: !memory.enabled } })); setError(null) } catch (err) { setError(errorMessage(err)) }
  }
  return <section><div className="co-setting-card"><div className="co-setting-row"><div><b>{t('Workspace memory')}</b><p>{t('A continuously compacted Markdown summary shared across your chats.')}</p></div><Switch checked={memory?.enabled ?? false} label={t('Workspace memory enabled')} onChange={() => void toggle()} /></div><div className="co-memory-meta">{memory ? `${t('{count} compactions', { count: memory.compactionCount })} · ${t('{count} source exchanges', { count: memory.sources.length })}${memory.pendingEntries ? ` · ${t('{count} pending', { count: memory.pendingEntries })}` : ''}` : t('Loading')}</div><p className="co-panel-note">{t('Pausing stops new memories from being recorded. It does not delete the existing summary. Memory contains concise facts, not private reasoning.')}</p><pre className="co-memory-doc">{memory?.markdown ?? t('Loading')}</pre><a className="co-secondary-button co-download" href="/api/workspace/memory/export" download><Icon name="file" size={14} />{t('Export memory.md')}</a><ErrorBanner message={error} /></div></section>
}

function SettingsPanel({ onRestartGuide }: { onRestartGuide: () => Promise<void> }) {
  const { t } = useI18n()
  const { isAdmin, signOut } = useAuth()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  return <section><div className="co-setting-card"><h3>{t('Your preferences')}</h3><div className="co-setting-row"><span>{t('Language')}</span><LanguageToggle /></div><Link className="co-setting-link" to="/account">{t('Account & app tokens')} →</Link>{isAdmin ? <><Link className="co-setting-link" to="/settings">{t('Model providers')} →</Link><Link className="co-setting-link" to="/people">{t('People & invitations')} →</Link></> : null}<Link className="co-setting-link" to="/missions">{t('Mission history & files')} →</Link></div>
    <div className="co-guide-reset"><h3>{t('A quick guide, whenever you need it')}</h3><p>{t('Three short steps explain chat, teams, and connections. Restarting changes only the guide—not your chats, teams, providers, connections, or memory.')}</p><button className="co-secondary-button" disabled={busy} onClick={() => { setBusy(true); setError(null); void onRestartGuide().catch((err) => setError(errorMessage(err))).finally(() => setBusy(false)) }}><Icon name="memory" size={14} />{t('Restart the guide')}</button><ErrorBanner message={error} /></div>
    <button className="co-secondary-button co-signout" onClick={() => void signOut()}>{t('Sign out')}</button>
  </section>
}

export function WorkspacePanel({ panel, teams, connectors, memory, onConnectors, onMemory, onClose, onNewTeam, onRestartGuide }: { panel: PanelName; teams: Team[]; connectors: ConnectorStatus[]; memory: WorkspaceMemory | null; onConnectors: (connectors: ConnectorStatus[]) => void; onMemory: (memory: WorkspaceMemory) => void; onClose: () => void; onNewTeam: () => void; onRestartGuide: () => Promise<void> }) {
  const { t } = useI18n()
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    if (panel !== 'connections') return
    api<ConnectorStatus[]>('connectors').then(onConnectors).catch((err) => setError(errorMessage(err)))
  }, [panel, onConnectors])
  const content = {
    teams: { title: t('Teams'), eyebrow: t('Your specialist workspace'), description: t('One coordinator, the right specialists, one clear response.') },
    connections: { title: t('Connections'), eyebrow: t('Bring your tools'), description: t('Give Ada and your teams access to the services you choose.') },
    memory: { title: t('Workspace memory'), eyebrow: t('Context that carries forward'), description: t('Inspect the actual Markdown Ada uses across your workspace.') },
    settings: { title: t('Settings & guide'), eyebrow: t('Make it yours'), description: t('Simple controls, without resetting your work.') },
  }[panel]
  return <Drawer {...content} onClose={onClose}>
    {panel === 'teams' ? <TeamsPanel teams={teams} onNewTeam={onNewTeam} /> : null}
    {panel === 'connections' ? <section><ErrorBanner message={error} />{connectors.map((connector) => <ConnectorCard key={connector.id} connector={connector} onChange={(updated) => onConnectors(connectors.map((item) => item.id === updated.id ? updated : item))} />)}<div className="co-safety-note"><Icon name="shield" /><p>{t('Ada’s direct chat access is read-only. Drafting, sending, and DNS writes are separate permissions for team workers.')}</p></div></section> : null}
    {panel === 'memory' ? <MemoryPanel memory={memory} onChange={onMemory} /> : null}
    {panel === 'settings' ? <SettingsPanel onRestartGuide={onRestartGuide} /> : null}
  </Drawer>
}
