import { useEffect, useMemo, useRef, useState, type TouchEvent } from 'react'
import { useDialogs } from '../ConfirmDialog'
import { Link, NavLink } from 'react-router-dom'
import type { ConversationSummary } from '../../api/types'
import { useAuth } from '../../auth/AuthContext'
import { useI18n } from '../../i18n'
import { chatTitle, groupedConversations, splitByToday } from '../../lib/coordinator'
import { Icon } from './Icon'

interface Props {
  conversations: ConversationSummary[]
  selectedID: string | null
  open: boolean
  onClose: () => void
  onSelect: (id: string) => void
  onNew: (projectName?: string) => void
  /** The project of a chat that is open but not saved yet. Shown as a row so a newly named project is visible. */
  pendingProject?: string | null
  /** Archives a chat. Left out on pages that cannot archive, which hides the archive buttons. */
  onArchive?: (id: string) => void
  onShowArchived: () => void
  /** The chat just archived, offered for a quick undo. */
  archivedNotice?: { id: string; title: string } | null
  onUndoArchive?: () => void
}

/** Swipe left at least this far (px) on a phone to reveal a chat's archive button. */
const SWIPE_REVEAL = 36

export function CoordinatorSidebar({ conversations, selectedID, open, onClose, onSelect, onNew, pendingProject, onArchive, onShowArchived, archivedNotice, onUndoArchive }: Props) {
  const { t } = useI18n()
  const { me } = useAuth()
  const dialogs = useDialogs()
  const [query, setQuery] = useState('')
  const filtered = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    return normalized ? conversations.filter((conversation) => conversation.title.toLowerCase().includes(normalized)) : conversations
  }, [conversations, query])
  const groups = groupedConversations(filtered)
  const select = (id: string) => { onSelect(id); onClose() }
  // Touch screens have no hover: a left swipe on a chat reveals its archive button instead.
  const [revealed, setRevealed] = useState<string | null>(null)
  const swipe = useRef<{ id: string; x: number; y: number } | null>(null)
  useEffect(() => { if (!open) setRevealed(null) }, [open])
  const touchStart = (id: string, event: TouchEvent) => {
    const touch = event.touches[0]
    swipe.current = touch ? { id, x: touch.clientX, y: touch.clientY } : null
  }
  const touchMove = (event: TouchEvent) => {
    const start = swipe.current
    const touch = event.touches[0]
    if (!start || !touch) return
    const dx = touch.clientX - start.x
    const dy = Math.abs(touch.clientY - start.y)
    if (dy > 24) { swipe.current = null; return }
    if (dx < -SWIPE_REVEAL) { setRevealed(start.id); swipe.current = null }
    else if (dx > SWIPE_REVEAL) { setRevealed(null); swipe.current = null }
  }
  const archive = (id: string) => { setRevealed(null); onArchive?.(id) }
  // A project named a moment ago has no saved chat yet; show it so the name is not lost from view.
  const pending = pendingProject?.trim()
  const newProject = pending && pending !== 'Personal' && !query.trim() && !conversations.some((chat) => (chat.projectName.trim() || 'Personal') === pending) ? pending : null
  const chatRow = (chat: ConversationSummary) => <div key={chat.id} className={`co-chat-row ${selectedID === chat.id ? 'active' : ''} ${revealed === chat.id ? 'revealed' : ''}`} onTouchStart={onArchive ? (event) => touchStart(chat.id, event) : undefined} onTouchMove={onArchive ? touchMove : undefined}>
    <button className={`co-chat-link ${selectedID === chat.id ? 'active' : ''}`} onClick={() => revealed === chat.id ? setRevealed(null) : select(chat.id)} title={chatTitle(chat.title, t)}>
      {chat.running ? <span className="co-live-dot" /> : null}{chatTitle(chat.title, t)}
    </button>
    {onArchive ? <button className="co-chat-archive" aria-label={t('Archive {title}', { title: chatTitle(chat.title, t) })} title={t('Archive chat')} onClick={() => archive(chat.id)}><Icon name="close" size={13} /></button> : null}
  </div>

  return <>
    {open ? <div className="co-nav-scrim" onClick={onClose} /> : null}
    <aside className={`co-sidebar ${open ? 'open' : ''}`} aria-label={t('Workspace sidebar')}>
      <Link to="/" className="co-brand" aria-label={t('Ada home')}><span className="co-brand-mark">A</span><span>Ada</span></Link>
      <div className="co-sidebar-top">
        <button className="co-new-chat" onClick={() => { onNew(); onClose() }}><Icon name="plus" size={15} />{t('New chat')}</button>
        <label className="co-search"><Icon name="search" size={14} /><input value={query} id="co-chat-search" aria-label={t('Search chats')} placeholder={t('Search chats')} onChange={(event) => setQuery(event.target.value)} /><span>⌘K</span></label>
      </div>
      <div className="co-side-scroll">
        <section className="co-side-section">
          <div className="co-side-label">{t('Projects')}<button aria-label={t('New project')} onClick={async () => {
            const name = await dialogs.ask({ title: t('New project'), detail: t('Chats in a project are grouped together in the list.'), label: t('Project name'), confirm: t('Create project') })
            if (name) { onNew(name); onClose() }
          }}><Icon name="plus" size={14} /></button></div>
          {groups.map(([project, chats]) => {
            const { today, earlier } = splitByToday(chats)
            const dated = today.length > 0 && earlier.length > 0
            return <div className="co-project" key={project}>
              <div className="co-project-row"><Icon name="folder" size={14} /><span>{project === 'Personal' ? t('Personal') : project}</span><span className="co-count">{chats.length}</span></div>
              <div className="co-project-chats">
                {dated ? <div className="co-chat-day">{t('Today')}</div> : null}
                {today.map(chatRow)}
                {dated ? <div className="co-chat-day">{t('Earlier')}</div> : null}
                {earlier.map(chatRow)}
              </div>
            </div>
          })}
          {newProject ? <div className="co-project pending">
            <div className="co-project-row"><Icon name="folder" size={14} /><span>{newProject}</span></div>
            <div className="co-project-chats"><p className="co-chat-pending">{t('Send a message to start this project.')}</p></div>
          </div> : null}
          {groups.length === 0 && !newProject ? <p className="co-side-empty">{t('No conversations found.')}</p> : null}
          {archivedNotice ? <div className="co-archive-toast" role="status"><span>{t('Chat archived')}</span>{onUndoArchive ? <button onClick={onUndoArchive}>{t('Undo')}</button> : null}</div> : null}
</section>
      </div>
      <div className="co-sidebar-foot">
        {/* Everything that isn't a chat lives in three places: past work, archived chats, and Settings. */}
        <NavLink to="/missions" className={({ isActive }) => `co-side-item ${isActive ? 'active' : ''}`} onClick={onClose}><Icon name="activity" size={15} /><span>{t('History')}</span></NavLink>
        <button className="co-side-item co-archived-link" onClick={() => { onShowArchived(); onClose() }}><Icon name="archive" size={15} /><span>{t('Archived chats')}</span></button>
        <NavLink to="/settings" className={({ isActive }) => `co-profile ${isActive ? 'active' : ''}`} aria-label={t('Settings')} onClick={onClose}><span className="co-profile-avatar">{(me?.name.trim()[0] ?? 'A').toUpperCase()}</span><span><b>{me?.name}</b><small>{me?.role ? t(me.role) : ''}</small></span><Icon name="settings" size={16} /></NavLink>
      </div>
    </aside>
  </>
}
