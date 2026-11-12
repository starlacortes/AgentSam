import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import type { ConversationSummary, Team } from '../../api/types'
import { useAuth } from '../../auth/AuthContext'
import { useI18n } from '../../i18n'
import { groupedConversations } from '../../lib/coordinator'
import { Icon } from './Icon'

export type PanelName = 'teams' | 'connections' | 'memory' | 'settings'

interface Props {
  conversations: ConversationSummary[]
  teams: Team[]
  selectedID: string | null
  open: boolean
  onClose: () => void
  onSelect: (id: string) => void
  onNew: (projectName?: string) => void
  onPanel: (panel: PanelName) => void
  memoryEnabled: boolean
}

export function CoordinatorSidebar({ conversations, teams, selectedID, open, onClose, onSelect, onNew, onPanel, memoryEnabled }: Props) {
  const { t } = useI18n()
  const { me } = useAuth()
  const [query, setQuery] = useState('')
  const filtered = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    return normalized ? conversations.filter((conversation) => conversation.title.toLowerCase().includes(normalized)) : conversations
  }, [conversations, query])
  const groups = groupedConversations(filtered)
  const select = (id: string) => { onSelect(id); onClose() }

  return <>
    {open ? <div className="co-nav-scrim" onClick={onClose} /> : null}
    <aside className={`co-sidebar ${open ? 'open' : ''}`} aria-label={t('Workspace sidebar')}>
      <Link to="/" className="co-brand" aria-label={t('AgentSam home')}><span className="co-brand-mark">A</span><span>AgentSam</span><span className="co-brand-badge">ADA</span></Link>
      <div className="co-sidebar-top">
        <button className="co-new-chat" onClick={() => { onNew(); onClose() }}><Icon name="plus" size={15} />{t('New chat')}</button>
        <label className="co-search"><Icon name="search" size={14} /><input value={query} id="co-chat-search" aria-label={t('Search chats')} placeholder={t('Search chats')} onChange={(event) => setQuery(event.target.value)} /><span>⌘K</span></label>
      </div>
      <div className="co-side-scroll">
        <section className="co-side-section">
          <div className="co-side-label">{t('Projects')}<button aria-label={t('New project')} onClick={() => {
            const name = window.prompt(t('Project name'))
            if (name?.trim()) { onNew(name.trim()); onClose() }
          }}><Icon name="plus" size={14} /></button></div>
          {groups.map(([project, chats]) => <div className="co-project" key={project}>
            <div className="co-project-row"><Icon name="folder" size={14} /><span>{project === 'Personal' ? t('Personal') : project}</span><span className="co-count">{chats.length}</span></div>
            <div className="co-project-chats">{chats.map((chat) => <button key={chat.id} className={`co-chat-link ${selectedID === chat.id ? 'active' : ''}`} onClick={() => select(chat.id)} title={chat.title}>
              {chat.running ? <span className="co-live-dot" /> : null}{chat.title}
            </button>)}</div>
          </div>)}
          {groups.length === 0 ? <p className="co-side-empty">{t('No conversations found.')}</p> : null}
        </section>
        <section className="co-side-section">
          <div className="co-side-label">{t('Active teams')}</div>
          {teams.slice(0, 5).map((team) => <button className="co-side-item" key={team.id} onClick={() => onPanel('teams')}><Icon name="users" size={14} /><span>{team.name}</span><span className="co-count">{team.agents.length}</span></button>)}
        </section>
      </div>
      <div className="co-sidebar-foot">
        <button className="co-side-item" onClick={() => onPanel('teams')}><Icon name="users" size={15} />{t('Teams')}</button>
        <button className="co-side-item" onClick={() => onPanel('connections')}><Icon name="plug" size={15} />{t('Connections')}</button>
        <button className="co-side-item" onClick={() => onPanel('settings')}><Icon name="settings" size={15} />{t('Settings & guide')}</button>
        <button className="co-profile" onClick={() => onPanel('memory')}><span className="co-profile-avatar">{(me?.name.trim()[0] ?? 'A').toUpperCase()}</span><span><b>{me?.name}</b><small>{memoryEnabled ? t('Workspace memory on') : t('Workspace memory paused')}</small></span><i className={memoryEnabled ? 'co-online-dot' : 'co-offline-dot'} /></button>
      </div>
    </aside>
  </>
}
