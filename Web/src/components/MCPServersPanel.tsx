import { useEffect, useState } from 'react'
import { api, errorMessage } from '../api/client'
import type { MCPServerView, MCPSuggestionView } from '../api/types'
import { useI18n } from '../i18n'
import { Icon } from './coordinator/Icon'
import { Switch } from './coordinator/WorkspacePanels'
import { ErrorBanner } from './ui'

/** Admin list of connected MCP servers: add by URL, choose which tools only read, switch off or remove. */
export function MCPServersPanel() {
  const { t } = useI18n()
  const [servers, setServers] = useState<MCPServerView[] | null>(null)
  const [name, setName] = useState('')
  const [url, setURL] = useState('')
  const [token, setToken] = useState('')
  const [open, setOpen] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [suggestions, setSuggestions] = useState<MCPSuggestionView[]>([])
  const [failed, setFailed] = useState<string[]>([])

  useEffect(() => {
    void api<MCPServerView[]>('mcp/servers').then(setServers).catch((err) => setError(errorMessage(err)))
    void api<MCPSuggestionView[]>('mcp/catalog').then(setSuggestions).catch(() => setSuggestions([]))
  }, [])

  const run = async (work: () => Promise<void>) => {
    setBusy(true)
    setError(null)
    try { await work() } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const replace = (server: MCPServerView) => setServers((list) => (list ?? []).map((item) => item.id === server.id ? server : item))
  const add = () => run(async () => {
    const server = await api<MCPServerView>('mcp/servers', { method: 'POST', body: { name, url, token: token || undefined } })
    setServers((list) => [...(list ?? []), server])
    setName('')
    setURL('')
    setToken('')
    setOpen(server.id)
  })
  /** Connects suggested servers one by one; one that does not answer is skipped and named. */
  const addSuggested = (items: MCPSuggestionView[]) => run(async () => {
    const missed: string[] = []
    for (const item of items) {
      try {
        const server = await api<MCPServerView>('mcp/servers', { method: 'POST', body: { name: item.name, url: item.url } })
        setServers((list) => [...(list ?? []), server])
        setSuggestions((list) => list.map((entry) => entry.id === item.id ? { ...entry, added: true } : entry))
      } catch { missed.push(item.name) }
    }
    setFailed(missed)
  })
  const update = (server: MCPServerView, body: { enabled?: boolean; readTools?: string[] }) => run(async () => {
    replace(await api<MCPServerView>(`mcp/servers/${server.id}`, { method: 'PUT', body }))
  })
  const refresh = (server: MCPServerView) => run(async () => { replace(await api<MCPServerView>(`mcp/servers/${server.id}/refresh`, { method: 'POST' })) })
  const remove = (server: MCPServerView) => run(async () => {
    await api(`mcp/servers/${server.id}`, { method: 'DELETE' })
    setServers((list) => (list ?? []).filter((item) => item.id !== server.id))
  })
  const toggleRead = (server: MCPServerView, tool: string, read: boolean) => {
    const reads = server.tools.filter((item) => item.name === tool ? read : item.read).map((item) => item.name)
    void update(server, { readTools: reads })
  }

  return <section className="co-setting-card mcp-servers">
    <div className="co-setting-row"><div>
      <b>{t('MCP servers')}</b>
      <p>{t('Connect any MCP server by its URL, and Ada can use its tools. Tools you mark as read-only run at once; every other tool asks for your approval first, unless a rule under What Ada can do alone allows it.')}</p>
    </div></div>
    {servers?.length ? <ul className="mcp-list">
      {servers.map((server) => <li key={server.id}>
        <div className="mcp-head">
          <div><b>{server.name}</b><p><code>{server.url}</code> · {t('{count} tools', { count: server.tools.length })}{server.hasToken ? ` · ${t('token saved')}` : ''}</p>{server.lastError ? <p className="danger">{server.lastError}</p> : null}</div>
          <div className="mcp-actions">
            <Switch checked={server.enabled} disabled={busy} label={t('Use {name}', { name: server.name })} onChange={() => void update(server, { enabled: !server.enabled })} />
            <button className="co-text-button" disabled={busy} onClick={() => setOpen(open === server.id ? null : server.id)}>{open === server.id ? t('Hide tools') : t('Tools')}</button>
            <button className="co-text-button" disabled={busy} title={t('Refresh tools')} aria-label={t('Refresh tools')} onClick={() => void refresh(server)}><Icon name="refresh" size={12} /></button>
            <button className="co-text-button danger" disabled={busy} title={t('Remove')} aria-label={t('Remove')} onClick={() => void remove(server)}><Icon name="trash" size={12} /></button>
          </div>
        </div>
        {open === server.id ? <ul className="mcp-tools">
          {server.tools.map((tool) => <li key={tool.name}>
            <label><input type="checkbox" disabled={busy} checked={tool.read} onChange={(event) => toggleRead(server, tool.name, event.target.checked)} /> <code>{tool.name}</code> {tool.read ? t('read-only, runs at once') : t('asks first')}</label>
            {tool.description ? <p>{tool.description}</p> : null}
          </li>)}
        </ul> : null}
      </li>)}
    </ul> : servers ? <p className="co-panel-note">{t('No MCP servers yet.')}</p> : null}
    {suggestions.some((item) => !item.added) ? <div className="mcp-suggested">
      <div className="mcp-head"><b>{t('Free servers to add')}</b><button className="co-secondary-button" disabled={busy} onClick={() => void addSuggested(suggestions.filter((item) => !item.added))}><Icon name="plus" size={14} />{t('Add all')}</button></div>
      <ul className="mcp-tools">
        {suggestions.filter((item) => !item.added).map((item) => <li key={item.id} className="mcp-suggestion">
          <div><b>{item.name}</b><p>{item.detail}</p></div>
          <button className="co-text-button" disabled={busy} onClick={() => void addSuggested([item])}><Icon name="plus" size={12} />{t('Add')}</button>
        </li>)}
      </ul>
      {failed.length ? <p className="danger">{t('These did not answer and were skipped: {names}', { names: failed.join(', ') })}</p> : null}
    </div> : null}
    <form className="mcp-form" onSubmit={(event) => { event.preventDefault(); if (url.trim()) void add() }}>
      <input className="input" type="text" value={name} maxLength={60} placeholder={t('Name')} aria-label={t('Name')} onChange={(event) => setName(event.target.value)} />
      <input className="input" type="url" value={url} placeholder="https://example.com/mcp" aria-label={t('Server URL')} onChange={(event) => setURL(event.target.value)} />
      <input className="input" type="password" value={token} autoComplete="off" placeholder={t('Bearer token (optional)')} aria-label={t('Bearer token (optional)')} onChange={(event) => setToken(event.target.value)} />
      <button className="co-secondary-button" disabled={busy || !url.trim()} type="submit"><Icon name="plus" size={14} />{t('Connect')}</button>
    </form>
    <ErrorBanner message={error} />
  </section>
}
