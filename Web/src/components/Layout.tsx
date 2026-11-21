import { useCallback, useEffect, useState } from 'react'
import { Outlet, useLocation, useNavigate } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import type { Conversation, ConversationSummary } from '../api/types'
import { useI18n, type Lang } from '../i18n'
import { CoordinatorSidebar } from './coordinator/CoordinatorSidebar'
import { Icon } from './coordinator/Icon'
import { ErrorBanner } from './ui'

/** English/Spanish switch, used in Settings and the voice screen. */
export function LanguageToggle() {
  const { lang, setLang, t } = useI18n()
  const pill = (code: Lang) => (lang === code ? 'pill active' : 'pill')
  return (
    <div className="lang-toggle" role="group" aria-label={t('Language')}>
      <button className={pill('en')} aria-pressed={lang === 'en'} onClick={() => setLang('en')}>
        EN
      </button>
      <button className={pill('es')} aria-pressed={lang === 'es'} onClick={() => setLang('es')}>
        ES
      </button>
    </div>
  )
}

/**
 * One layout for the whole app: the chat sidebar on the left and the page on the right.
 * The chat screen draws its own sidebar (it owns the live chat list), so it renders bare here.
 */
export function Layout() {
  const location = useLocation()
  if (location.pathname === '/' || location.pathname.startsWith('/chats/')) return <Outlet />
  return <PageShell />
}

function PageShell() {
  const { t } = useI18n()
  const navigate = useNavigate()
  const location = useLocation()
  const [conversations, setConversations] = useState<ConversationSummary[]>([])
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    void api<ConversationSummary[]>('conversations').then(setConversations).catch(() => { /* the page still works without the list */ })
  }, [])
  useEffect(() => { setSidebarOpen(false) }, [location.pathname])

  const newChat = useCallback(async (project?: string) => {
    if (!project) { navigate('/'); return }
    try {
      const created = await api<Conversation>('conversations', { method: 'POST', body: { projectName: project } })
      navigate(`/chats/${created.id}`)
    } catch (err) { setError(errorMessage(err)) }
  }, [navigate])

  return (
    <div className="co-app app-shell">
      <CoordinatorSidebar
        conversations={conversations}
        selectedID={null}
        open={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
        onSelect={(id) => navigate(`/chats/${id}`)}
        onNew={(project) => void newChat(project)}
        onShowArchived={() => navigate('/?archived=1')}
      />
      <main className="co-main shell-main">
        <header className="shell-header">
          <button className="co-icon-button co-menu-button" aria-label={t('Open workspace sidebar')} onClick={() => setSidebarOpen(true)}><Icon name="menu" /></button>
        </header>
        <div className="shell-scroll">
          <div className="page">
            <ErrorBanner message={error} />
            <Outlet />
          </div>
        </div>
      </main>
    </div>
  )
}
