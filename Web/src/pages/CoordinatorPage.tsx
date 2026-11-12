import { useCallback, useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import type { ConnectorStatus, Conversation, ConversationSummary, GuideState, ProviderStatus, Team, WorkspaceMemory } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { AgentWorkroom } from '../components/coordinator/AgentWorkroom'
import { CoordinatorSidebar, type PanelName } from '../components/coordinator/CoordinatorSidebar'
import { ConversationMessages } from '../components/coordinator/ConversationMessages'
import { Guide } from '../components/coordinator/Guide'
import { Icon } from '../components/coordinator/Icon'
import { VoiceMode, type VoiceReply } from '../components/coordinator/VoiceMode'
import { WorkspacePanel } from '../components/coordinator/WorkspacePanels'
import { ErrorBanner, Spinner } from '../components/ui'
import { useI18n } from '../i18n'
import { connectorLabel, shouldPoll } from '../lib/coordinator'
import { transcribeConversation } from '../lib/voice'
import { useDocumentTitle } from '../lib/useDocumentTitle'

function mergeConversation(list: ConversationSummary[], conversation: Conversation): ConversationSummary[] {
  return [conversation, ...list.filter((item) => item.id !== conversation.id)].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
}

export function CoordinatorPage() {
  const { id } = useParams()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const { t, lang } = useI18n()
  const { isAdmin } = useAuth()
  const [conversations, setConversations] = useState<ConversationSummary[]>([])
  const [conversation, setConversation] = useState<Conversation | null>(null)
  const [teams, setTeams] = useState<Team[]>([])
  const [connectors, setConnectors] = useState<ConnectorStatus[]>([])
  const [providers, setProviders] = useState<ProviderStatus[]>([])
  const [memory, setMemory] = useState<WorkspaceMemory | null>(null)
  const [guide, setGuide] = useState<GuideState | null>(null)
  const [draft, setDraft] = useState('')
  const [projectName, setProjectName] = useState('Personal')
  const [panel, setPanel] = useState<PanelName | null>(null)
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [voiceOpen, setVoiceOpen] = useState(false)
  const [loading, setLoading] = useState(true)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const input = useRef<HTMLTextAreaElement>(null)
  const sendLock = useRef(false)
  const mounted = useRef(true)
  const running = shouldPoll(conversation)
  const hasProvider = providers.some((provider) => provider.hasKey)
  const gmail = connectors.find((connector) => connector.id === 'gmail')
  useDocumentTitle(conversation?.title ?? t('Chat'))

  const replaceConversation = useCallback((next: Conversation) => {
    setConversation((current) => current?.id === next.id && current.updatedAt > next.updatedAt ? current : next)
    setConversations((current) => mergeConversation(current, next))
  }, [])

  const refreshWorkspace = useCallback(async () => {
    const [chats, teamList, currentMemory] = await Promise.all([
      api<ConversationSummary[]>('conversations'),
      api<Team[]>('teams'),
      api<WorkspaceMemory>('workspace/memory'),
    ])
    if (!mounted.current) return
    setConversations(chats)
    setTeams(teamList)
    setMemory(currentMemory)
  }, [])

  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const [chats, teamList, connectionList, providerList, currentMemory, guideState] = await Promise.all([
          api<ConversationSummary[]>('conversations'),
          api<Team[]>('teams'),
          api<ConnectorStatus[]>('connectors'),
          api<ProviderStatus[]>('providers'),
          api<WorkspaceMemory>('workspace/memory'),
          api<GuideState>('workspace/guide'),
        ])
        if (!active) return
        setConversations(chats)
        setTeams(teamList)
        setConnectors(connectionList)
        setProviders(providerList)
        setMemory(currentMemory)
        setGuide(guideState)
      } catch (err) {
        if (active) setError(errorMessage(err))
      } finally {
        if (active) setLoading(false)
      }
    })()
    return () => { active = false }
  }, [])

  useEffect(() => {
    if (!id) {
      setConversation(null)
      return
    }
    let active = true
    void api<Conversation>(`conversations/${id}`).then((result) => {
      if (active) replaceConversation(result)
    }).catch((err) => {
      if (active) setError(errorMessage(err))
    })
    return () => { active = false }
  }, [id, replaceConversation])

  useEffect(() => {
    if (!running || !conversation || !shouldPoll(conversation)) return
    const currentID = conversation.id
    const timer = window.setTimeout(() => {
      void api<Conversation>(`conversations/${currentID}`).then((result) => {
        if (!mounted.current) return
        replaceConversation(result)
        if (!shouldPoll(result)) void refreshWorkspace().catch((err) => setError(errorMessage(err)))
      }).catch((err) => {
        if (mounted.current) setError(errorMessage(err))
      })
    }, 900)
    return () => window.clearTimeout(timer)
  }, [conversation, running, replaceConversation, refreshWorkspace])

  useEffect(() => {
    const shortcut = (event: globalThis.KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setSidebarOpen(true)
        window.setTimeout(() => document.getElementById('co-chat-search')?.focus(), 0)
      }
    }
    window.addEventListener('keydown', shortcut)
    return () => window.removeEventListener('keydown', shortcut)
  }, [])

  const newChat = async (project?: string) => {
    setError(null)
    try {
      const result = await api<Conversation>('conversations', { method: 'POST', body: { projectName: project ?? 'Personal' } })
      setProjectName(project ?? 'Personal')
      replaceConversation(result)
      setDraft('')
      navigate(`/chats/${result.id}`)
      input.current?.focus()
    } catch (err) { setError(errorMessage(err)) }
  }

  const ensureConversation = async (): Promise<Conversation> => {
    if (conversation) return conversation
    const current = await api<Conversation>('conversations', { method: 'POST', body: { projectName } })
    replaceConversation(current)
    navigate(`/chats/${current.id}`, { replace: true })
    return current
  }

  const transcribeVoice = async (audio: Blob): Promise<string> => {
    const current = await ensureConversation()
    return transcribeConversation(current.id, audio, lang)
  }

  const sendMessage = async (raw: string, waitForCompletion = false): Promise<VoiceReply | null> => {
    const text = raw.trim()
    if (!text || sendLock.current || (conversation && shouldPoll(conversation))) return null
    sendLock.current = true
    setSending(true)
    setError(null)
    try {
      const current = await ensureConversation()
      const result = await api<Conversation>(`conversations/${current.id}/messages`, { method: 'POST', body: { text, language: lang } })
      if (!mounted.current) return null
      replaceConversation(result)
      setDraft('')
      if (!waitForCompletion) return null
      for (let attempt = 0; attempt < 240; attempt += 1) {
        await new Promise((resolve) => window.setTimeout(resolve, 900))
        if (!mounted.current) return null
        const next = await api<Conversation>(`conversations/${current.id}`)
        replaceConversation(next)
        const answer = next.messages.at(-1)
        if (answer && answer.status !== 'running') {
          await refreshWorkspace()
          return answer.status === 'complete' ? { text: answer.text, speechURL: `/api/conversations/${current.id}/messages/${answer.id}/speech?lang=${lang}` } : null
        }
      }
      setError(t('This response is taking longer than expected. Keep the chat open, or return to it later.'))
      return null
    } catch (err) {
      if (mounted.current) setError(errorMessage(err))
      return null
    } finally {
      sendLock.current = false
      if (mounted.current) setSending(false)
    }
  }

  const submit = (event: FormEvent) => {
    event.preventDefault()
    void sendMessage(draft)
  }

  const composeKey = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault()
      void sendMessage(draft)
    }
  }

  const prompt = (text: string) => {
    setDraft(text)
    setPanel(null)
    window.setTimeout(() => {
      input.current?.focus()
      input.current?.setSelectionRange(text.length, text.length)
    }, 0)
  }

  const retry = (text: string) => {
    prompt(text)
  }

  const stop = async () => {
    if (!conversation) return
    try {
      await api(`conversations/${conversation.id}/stop`, { method: 'POST' })
      await new Promise((resolve) => window.setTimeout(resolve, 250))
      replaceConversation(await api<Conversation>(`conversations/${conversation.id}`))
    } catch (err) { setError(errorMessage(err)) }
  }

  const remove = async () => {
    if (!conversation || !window.confirm(t('Delete this conversation? Its messages will be removed; missions, teams, and files stay intact.'))) return
    try {
      await api(`conversations/${conversation.id}`, { method: 'DELETE' })
      setConversations((current) => current.filter((item) => item.id !== conversation.id))
      setConversation(null)
      navigate('/')
    } catch (err) { setError(errorMessage(err)) }
  }

  const finishGuide = async () => {
    const state = await api<GuideState>('workspace/guide', { method: 'PATCH', body: { completed: true } })
    setGuide(state)
    if (searchParams.has('guide')) setSearchParams({}, { replace: true })
  }

  const restartGuide = async () => {
    const state = await api<GuideState>('workspace/guide', { method: 'PATCH', body: { completed: false } })
    setGuide(state)
    setPanel(null)
    setSearchParams({ guide: '1' })
  }

  const updateProposal = (next: Conversation) => {
    replaceConversation(next)
    void refreshWorkspace().catch((err) => setError(errorMessage(err)))
  }

  const openPanel = (name: PanelName) => {
    setPanel(name)
    setSidebarOpen(false)
  }

  return <div className="co-app">
    <CoordinatorSidebar conversations={conversations} teams={teams} selectedID={conversation?.id ?? null} open={sidebarOpen} onClose={() => setSidebarOpen(false)} onSelect={(chatID) => navigate(`/chats/${chatID}`)} onNew={(project) => void newChat(project)} onPanel={openPanel} memoryEnabled={memory?.enabled ?? false} />
    <main className="co-main">
      <header className="co-chat-header">
        <button className="co-icon-button co-menu-button" aria-label={t('Open workspace sidebar')} onClick={() => setSidebarOpen(true)}><Icon name="menu" /></button>
        <div className="co-chat-heading"><span>{t(conversation?.projectName ?? projectName)} <span className="co-path-separator">/</span></span><h1>{conversation?.title ?? t('New conversation')}</h1></div>
        <div className="co-header-actions">
          <button className={`co-connection-pill ${gmail?.configured && gmail.enabled ? 'connected' : ''}`} onClick={() => openPanel('connections')}><Icon name="plug" size={13} /><span>{t(connectorLabel(gmail))}</span><i /></button>
          <button className="co-icon-button co-help-button" aria-label={t('Open the guide')} onClick={() => void restartGuide().catch((err) => setError(errorMessage(err)))}><Icon name="info" size={17} /></button>
          <button className="co-voice-button" onClick={() => setVoiceOpen(true)} disabled={sending}><Icon name="mic" size={15} /><span>{t('Voice')}</span></button>
          {conversation ? <button className="co-icon-button co-delete-chat" aria-label={t('Delete conversation')} disabled={running} onClick={() => void remove()}><Icon name="trash" size={16} /></button> : null}
        </div>
      </header>
      <AgentWorkroom conversation={conversation} teams={teams} />
      <div className="co-chat-body">
        {loading && id ? <div className="co-loading"><Spinner /></div> : <ConversationMessages conversation={conversation} onUpdated={updateProposal} onRevise={() => prompt(t('Please revise the proposed team: '))} onRetry={retry} onStarter={prompt} />}
      </div>
      <div className="co-composer-wrap">
        {!hasProvider && !loading ? <div className="co-provider-notice"><Icon name="info" size={16} /><p>{t('Add a model provider and API key before chatting with Ada.')}</p>{isAdmin ? <Link to="/settings">{t('Set up providers')} →</Link> : null}</div> : null}
        <ErrorBanner message={error} />
        <form className="co-composer" onSubmit={submit}>
          <textarea ref={input} value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={composeKey} aria-label={t('Message Ada')} placeholder={t('Ask a question, or describe an outcome…')} rows={1} maxLength={20000} disabled={running} />
          <div className="co-composer-foot"><span className="co-composer-hint">{t('Ada answers directly or brings in the right team.')}<span className="co-enter-hint"> · {t('Enter to send · Shift + Enter for a new line')}</span></span>{running ? <button className="co-stop-button" type="button" onClick={() => void stop()}><Icon name="stop" size={12} />{t('Stop')}</button> : <button className="co-send-button" type="submit" aria-label={t('Send message')} disabled={sending || !draft.trim() || !hasProvider}><Icon name="arrow" size={18} /></button>}</div>
        </form>
        <p className="co-composer-note">{t('Agent activity shows concise work summaries, not private reasoning. Review team proposals and connections before granting access.')}</p>
      </div>
    </main>
    {panel ? <WorkspacePanel panel={panel} teams={teams} connectors={connectors} memory={memory} onConnectors={setConnectors} onMemory={setMemory} onClose={() => setPanel(null)} onNewTeam={() => prompt(t('I need a team for '))} onRestartGuide={restartGuide} /> : null}
    {guide && (!guide.completed || searchParams.get('guide') === '1') ? <Guide onFinish={finishGuide} /> : null}
    {voiceOpen ? <VoiceMode onSend={sendMessage} onTranscribe={transcribeVoice} onClose={() => setVoiceOpen(false)} /> : null}
  </div>
}
