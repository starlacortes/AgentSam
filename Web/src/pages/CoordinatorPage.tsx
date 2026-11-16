import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ClipboardEvent, type DragEvent, type FormEvent, type KeyboardEvent } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { api, errorMessage, uploadProjectFile } from '../api/client'
import type { AgentActionRequest, ConnectorStatus, Conversation, ConversationSummary, GuideState, MissionDetail, ProviderStatus, Team, WorkspaceKnowledge, WorkspaceMemory } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { AgentWorkroom } from '../components/coordinator/AgentWorkroom'
import { CoordinatorSidebar, type PanelName } from '../components/coordinator/CoordinatorSidebar'
import { ConversationMessages, type MessageHandlers } from '../components/coordinator/ConversationMessages'
import { SidePanel, type CanvasState } from '../components/coordinator/SidePanel'
import { ScheduleModal } from '../components/coordinator/ScheduleModal'
import { Guide } from '../components/coordinator/Guide'
import { Icon } from '../components/coordinator/Icon'
import { VoiceMode, type VoiceReply } from '../components/coordinator/VoiceMode'
import { WorkspacePanel } from '../components/coordinator/WorkspacePanels'
import { ErrorBanner, Spinner } from '../components/ui'
import { useI18n } from '../i18n'
import { canvasForFinishedFiles, connectorLabel, pollDelay, shouldPoll, workspaceFileSource, wroteFreshFiles } from '../lib/coordinator'
import { pickEntry } from '../lib/preview'
import { transcribeConversation } from '../lib/voice'
import { useDocumentTitle } from '../lib/useDocumentTitle'

const DRAFT_PREFIX = 'agentsam.draft.'
const CANVAS_WIDTH_KEY = 'agentsam.canvasWidth'
const MAX_ATTACHMENT_BYTES = 200_000
const TEXT_ATTACHMENT = /\.(txt|md|markdown|csv|tsv|json|ya?ml|xml|html?|css|m?js|ts|tsx|jsx|py|rb|go|rs|swift|java|kt|c|h|cpp|sh|sql|log|toml|ini|env\.example)$/i

function readStored(key: string): string | null {
  try { return window.localStorage.getItem(key) } catch { return null }
}

function writeStored(key: string, value: string | null) {
  try {
    if (value) window.localStorage.setItem(key, value)
    else window.localStorage.removeItem(key)
  } catch { /* storage unavailable: drafts are a convenience only */ }
}

function clampCanvasWidth(width: number): number {
  return Math.round(Math.min(Math.max(width, 340), Math.max(340, window.innerWidth - 520)))
}

/** A dropped or pasted text file, as a fenced block the model can read. */
export function attachmentBlock(name: string, text: string): string {
  const ext = name.includes('.') ? name.split('.').pop()!.toLowerCase() : ''
  const fence = text.includes('```') ? '~~~~' : '```'
  return `${name}:\n${fence}${ext}\n${text.replace(/\s+$/, '')}\n${fence}\n`
}

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
  const [knowledge, setKnowledge] = useState<WorkspaceKnowledge | null>(null)
  const [guide, setGuide] = useState<GuideState | null>(null)
  const [draft, setDraft] = useState('')
  const [projectName, setProjectName] = useState('Personal')
  const [panel, setPanel] = useState<PanelName | null>(null)
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [voiceOpen, setVoiceOpen] = useState(false)
  const [scheduleOpen, setScheduleOpen] = useState(false)
  const [loading, setLoading] = useState(true)
  const [sending, setSending] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [actions, setActions] = useState<AgentActionRequest[]>([])
  const [error, setError] = useState<string | null>(null)
  const [canvas, setCanvas] = useState<CanvasState | null>(null)
  const [canvasWidth, setCanvasWidth] = useState(() => Number(readStored(CANVAS_WIDTH_KEY)) || 520)
  const [dragging, setDragging] = useState(false)
  const input = useRef<HTMLTextAreaElement>(null)
  const uploadInput = useRef<HTMLInputElement>(null)
  const draftKey = useRef<string>(`${DRAFT_PREFIX}new`)
  const carryDraft = useRef(false)
  const sendLock = useRef(false)
  const mounted = useRef(true)
  const running = shouldPoll(conversation)
  const hasProvider = providers.some((provider) => provider.hasKey)
  const gmail = connectors.find((connector) => connector.id === 'gmail')
  useDocumentTitle(conversation?.title ?? t('Chat'))
  const missionIDs = useMemo(() => [...new Set([...(conversation?.messages ?? [])].reverse().flatMap((message) => message.missionIDs))], [conversation?.messages])

  // Per-conversation drafts survive reloads and switching chats.
  useEffect(() => {
    const key = `${DRAFT_PREFIX}${id ?? 'new'}`
    if (key === draftKey.current) return
    draftKey.current = key
    if (carryDraft.current) { carryDraft.current = false; return }
    setDraft(readStored(key) ?? '')
  }, [id])
  useEffect(() => { writeStored(draftKey.current, draft) }, [draft])

  // A new chat starts with a fresh panel, kept open if it was.
  useEffect(() => { setCanvas((current) => current ? { tab: current.tab, source: null, missionID: null } : null) }, [id])

  // When Ada finishes a reply that wrote files, the sidebar opens them by itself — a page she
  // wrote goes straight to the preview tab. It fires once per message, and only for replies
  // this page watched go from running to complete (never for history loaded on open).
  const autoOpened = useRef<string>('')
  const observedWorking = useRef<string | null>(null)
  useEffect(() => {
    const running = [...(conversation?.messages ?? [])].reverse().find((message) => message.status === 'running')
    if (running) observedWorking.current = running.id
  }, [conversation?.messages])
  useEffect(() => {
    const conversationID = conversation?.id
    const target = conversation?.messages.find((message) => message.id === observedWorking.current)
    if (!conversationID || !target || target.status !== 'complete') return
    observedWorking.current = null
    if (autoOpened.current === target.id) return
    if (wroteFreshFiles(target)) {
      const next = canvasForFinishedFiles(target.fileIDs, target)
      if (!next) return
      autoOpened.current = target.id
      setCanvas((current) => current && current.source ? current : ({
        tab: next.tab,
        source: workspaceFileSource(conversationID, target.fileIDs),
        missionID: null,
      }))
      return
    }
    // A finished run (solo or a team) that produced a page opens it in the preview too.
    const missionID = target.missionIDs[0]
    if (!missionID) return
    let active = true
    void api<MissionDetail>(`missions/${missionID}`).then((detail) => {
      const entry = pickEntry(detail.deliverables)
      if (!active || !entry) return
      autoOpened.current = target.id
      setCanvas((current) => current && current.source ? current : ({
        tab: 'preview',
        source: { kind: 'mission', missionID, entry },
        missionID,
      }))
    }).catch(() => {})
    return () => { active = false }
  }, [conversation?.messages, conversation?.id])
  // Reset the once-per-message guard when switching conversations.
  useEffect(() => { autoOpened.current = ''; observedWorking.current = null }, [id])

  useLayoutEffect(() => {
    const element = input.current
    if (!element) return
    element.style.height = 'auto'
    element.style.height = `${Math.min(element.scrollHeight, 220)}px`
  }, [draft])

  const replaceConversation = useCallback((next: Conversation) => {
    setConversation((current) => current?.id === next.id && current.updatedAt > next.updatedAt ? current : next)
    setConversations((current) => mergeConversation(current, next))
  }, [])

  const refreshWorkspace = useCallback(async () => {
    const [chats, teamList, currentMemory, currentKnowledge] = await Promise.all([
      api<ConversationSummary[]>('conversations'),
      api<Team[]>('teams'),
      api<WorkspaceMemory>('workspace/memory'),
      api<WorkspaceKnowledge>('workspace/knowledge'),
    ])
    if (!mounted.current) return
    setConversations(chats)
    setTeams(teamList)
    setMemory(currentMemory)
    setKnowledge(currentKnowledge)
  }, [])

  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const [chats, teamList, connectionList, providerList, currentMemory, currentKnowledge, guideState] = await Promise.all([
          api<ConversationSummary[]>('conversations'),
          api<Team[]>('teams'),
          api<ConnectorStatus[]>('connectors'),
          api<ProviderStatus[]>('providers'),
          api<WorkspaceMemory>('workspace/memory'),
          api<WorkspaceKnowledge>('workspace/knowledge'),
          api<GuideState>('workspace/guide'),
        ])
        if (!active) return
        setConversations(chats)
        setTeams(teamList)
        setConnectors(connectionList)
        setProviders(providerList)
        setMemory(currentMemory)
        setKnowledge(currentKnowledge)
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
    setActions([])
    if (!id) return
    let active = true
    void api<AgentActionRequest[]>(`conversations/${id}/actions`).then((result) => { if (active) setActions(result) }).catch((err) => { if (active) setError(errorMessage(err)) })
    return () => { active = false }
  }, [id])

  useEffect(() => {
    const currentID = conversation?.id
    if (!currentID || (!running && !actions.some((action) => ['pending', 'approved', 'executing'].includes(action.status)))) return
    const timer = window.setTimeout(() => {
      void api<AgentActionRequest[]>(`conversations/${currentID}/actions`).then(setActions).catch((err) => { if (mounted.current) setError(errorMessage(err)) })
    }, 900)
    return () => window.clearTimeout(timer)
  }, [conversation?.id, running, actions])

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
    }, pollDelay(conversation))
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

  const stopRef = useRef<() => void>(() => {})
  useEffect(() => {
    const escape = (event: globalThis.KeyboardEvent) => {
      if (event.key !== 'Escape' || !running || voiceOpen || panel) return
      event.preventDefault()
      stopRef.current()
    }
    window.addEventListener('keydown', escape)
    return () => window.removeEventListener('keydown', escape)
  }, [running, voiceOpen, panel])

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
    carryDraft.current = true
    writeStored(draftKey.current, null)
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
      for (let attempt = 0; attempt < 700; attempt += 1) {
        await new Promise((resolve) => window.setTimeout(resolve, attempt === 0 ? 150 : 350))
        if (!mounted.current) return null
        const next = await api<Conversation>(`conversations/${current.id}`)
        replaceConversation(next)
        const answer = next.messages.at(-1)
        if (answer && answer.status !== 'running') {
          await refreshWorkspace()
          return answer.status === 'complete' ? { text: answer.text, speechURL: `/api/conversations/${current.id}/messages/${answer.id}/speech?lang=${lang}&chunk=0` } : null
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
    if (event.key === 'ArrowUp' && !draft && !event.shiftKey) {
      const last = [...(conversation?.messages ?? [])].reverse().find((message) => message.role === 'user')
      if (last) { event.preventDefault(); prompt(last.text) }
    }
  }

  const upload = async (files: File[]) => {
    if (!files.length || uploading) return
    setUploading(true); setError(null)
    try {
      const current = await ensureConversation()
      for (const file of files.slice(0, 5)) {
        if (!file.size || file.size > 5_000_000) throw new Error(t('{name} must be non-empty and at most 5 MB.', { name: file.name }))
        await uploadProjectFile(current.id, file, file.name)
      }
      openCanvas({ tab: 'files', source: { kind: 'project', conversationID: current.id } })
    } catch (err) { setError(errorMessage(err)) } finally { setUploading(false) }
  }

  const attach = async (files: FileList | File[]) => {
    const list = [...files]
    if (!list.length) return false
    const blocks: string[] = []
    for (const file of list.slice(0, 5)) {
      if (!(file.type.startsWith('text/') || file.type === 'application/json' || TEXT_ATTACHMENT.test(file.name))) { setError(t('Only text files can be added to a message.')); continue }
      if (file.size > MAX_ATTACHMENT_BYTES) { setError(t('{name} is larger than 200 KB.', { name: file.name })); continue }
      blocks.push(attachmentBlock(file.name, await file.text()))
    }
    if (blocks.length) {
      setDraft((current) => `${current}${current && !current.endsWith('\n') ? '\n\n' : ''}${blocks.join('\n')}`.slice(0, 20000))
      input.current?.focus()
    }
    return true
  }

  const drop = (event: DragEvent<HTMLFormElement>) => {
    event.preventDefault()
    setDragging(false)
    if (!running) void attach(event.dataTransfer.files)
  }

  const paste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    if (!event.clipboardData.files.length) return
    event.preventDefault()
    void attach(event.clipboardData.files)
  }

  const openCanvas = useCallback((next: Partial<CanvasState>) => {
    setCanvas((current) => ({
      tab: next.tab ?? current?.tab ?? 'preview',
      source: 'source' in next ? next.source ?? null : current?.source ?? null,
      missionID: 'missionID' in next ? next.missionID ?? null : current?.missionID ?? null,
    }))
    setPanel(null)
  }, [])

  const resizeCanvas = useCallback((width: number) => {
    const next = clampCanvasWidth(width)
    setCanvasWidth(next)
    writeStored(CANVAS_WIDTH_KEY, String(next))
  }, [])

  const prompt = (text: string) => {
    setDraft(text)
    setPanel(null)
    window.setTimeout(() => {
      input.current?.focus()
      input.current?.setSelectionRange(text.length, text.length)
    }, 0)
  }

  const stop = async () => {
    if (!conversation || !running) return
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
  stopRef.current = () => { void stop() }

  const handlers: MessageHandlers = {
    onUpdated: updateProposal,
    onRevise: () => prompt(t('Please revise the proposed team: ')),
    onRetry: (text) => void sendMessage(text),
    onEdit: prompt,
    onQuickReply: (text) => void sendMessage(text),
    onOpenCanvas: openCanvas,
    onStarter: prompt,
  }

  return <div className={`co-app ${canvas ? 'with-canvas' : ''}`} style={canvas ? { ['--co-canvas-width' as string]: `${clampCanvasWidth(canvasWidth)}px` } : undefined}>
    <CoordinatorSidebar conversations={conversations} teams={teams} selectedID={conversation?.id ?? null} open={sidebarOpen} onClose={() => setSidebarOpen(false)} onSelect={(chatID) => navigate(`/chats/${chatID}`)} onNew={(project) => void newChat(project)} onPanel={openPanel} memoryEnabled={memory?.enabled ?? false} />
    <main className="co-main">
      <header className="co-chat-header">
        <button className="co-icon-button co-menu-button" aria-label={t('Open workspace sidebar')} onClick={() => setSidebarOpen(true)}><Icon name="menu" /></button>
        <div className="co-chat-heading"><span>{t(conversation?.projectName ?? projectName)} <span className="co-path-separator">/</span></span><h1>{conversation?.title ?? t('New conversation')}</h1></div>
        <div className="co-header-actions">
          <button className={`co-connection-pill ${gmail?.configured && gmail.enabled ? 'connected' : ''}`} onClick={() => openPanel('connections')}><Icon name="plug" size={13} /><span>{t(connectorLabel(gmail))}</span><i /></button>
          {conversation ? <button className={`co-icon-button co-schedule-toggle ${conversation.schedule ? 'active' : ''}`} aria-label={conversation.schedule ? t('Recurring schedule on — open settings') : t('Set a recurring schedule')} aria-pressed={Boolean(conversation.schedule)} title={t('Recurring schedule')} disabled={!conversation.schedule && running} onClick={() => setScheduleOpen(true)}><Icon name="refresh" size={16} /></button> : null}
          <button className="co-icon-button co-help-button" aria-label={t('Open the guide')} onClick={() => void restartGuide().catch((err) => setError(errorMessage(err)))}><Icon name="info" size={17} /></button>
          <button className={`co-icon-button co-canvas-toggle ${canvas ? 'active' : ''}`} aria-label={canvas ? t('Hide preview and console') : t('Show preview and console')} aria-pressed={Boolean(canvas)} title={t('Preview & console')} onClick={() => canvas ? setCanvas(null) : openCanvas({ tab: missionIDs.length ? 'console' : 'preview' })}><Icon name="panel" size={16} /></button>
          <button className="co-voice-button" onClick={() => setVoiceOpen(true)} disabled={sending}><Icon name="mic" size={15} /><span>{t('Voice')}</span></button>
          {conversation ? <button className="co-icon-button co-delete-chat" aria-label={t('Delete conversation')} disabled={running} onClick={() => void remove()}><Icon name="trash" size={16} /></button> : null}
        </div>
      </header>
      <AgentWorkroom conversation={conversation} teams={teams} />
      <div className="co-chat-body">
        {loading && id ? <div className="co-loading"><Spinner /></div> : <ConversationMessages conversation={conversation} busy={sending || running} handlers={handlers} actions={actions} onActions={setActions} />}
      </div>
      <div className="co-composer-wrap">
        {!hasProvider && !loading ? <div className="co-provider-notice"><Icon name="info" size={16} /><p>{t('Add a model provider and API key before chatting with Ada.')}</p>{isAdmin ? <Link to="/settings">{t('Set up providers')} →</Link> : null}</div> : null}
        <ErrorBanner message={error} />
        <form className={`co-composer ${dragging ? 'dragging' : ''}`} onSubmit={submit} onDragOver={(event) => { if (event.dataTransfer.types.includes('Files')) { event.preventDefault(); setDragging(true) } }} onDragLeave={() => setDragging(false)} onDrop={drop}>
          <input ref={uploadInput} type="file" multiple hidden aria-label={t('Choose project files')} onChange={(event) => { const files = [...(event.currentTarget.files ?? [])]; event.currentTarget.value = ''; void upload(files) }} />
          {dragging ? <div className="co-drop-hint"><Icon name="file" size={16} />{t('Drop a text file to add it to your message')}</div> : null}
          <textarea ref={input} value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={composeKey} onPaste={paste} aria-label={t('Message Ada')} placeholder={t('Ask a question, or describe an outcome…')} rows={1} maxLength={20000} disabled={running} />
          <div className="co-composer-foot"><button type="button" className="co-icon-button co-upload-button" aria-label={t('Upload files to project')} title={t('Upload files to the shared project workspace (5 MB each)')} disabled={uploading} onClick={() => uploadInput.current?.click()}><Icon name={uploading ? 'refresh' : 'plus'} size={16} /></button><span className="co-composer-hint">{t('Ada answers directly or brings in the right team.')}<span className="co-enter-hint"> · {t('Enter to send · Shift + Enter for a new line')}</span></span>{running ? <button className="co-stop-button" type="button" onClick={() => void stop()} title={t('Stop (Esc)')}><Icon name="stop" size={12} />{t('Stop')}</button> : <button className="co-send-button" type="submit" aria-label={t('Send message')} disabled={sending || !draft.trim() || !hasProvider}><Icon name="arrow" size={18} /></button>}</div>
        </form>
        <p className="co-composer-note">{t('Agent activity shows concise work summaries, not private reasoning. Review team proposals and connections before granting access.')}</p>
      </div>
    </main>
    {canvas ? <SidePanel state={canvas} missionIDs={missionIDs} onChange={setCanvas} onClose={() => setCanvas(null)} onResize={resizeCanvas} /> : null}
    {scheduleOpen && conversation ? <ScheduleModal conversation={conversation} onUpdated={updateProposal} onClose={() => setScheduleOpen(false)} /> : null}
    {panel ? <WorkspacePanel panel={panel} teams={teams} connectors={connectors} memory={memory} knowledge={knowledge} onConnectors={setConnectors} onMemory={setMemory} onKnowledge={setKnowledge} onClose={() => setPanel(null)} onNewTeam={() => prompt(t('I need a team for '))} onRestartGuide={restartGuide} /> : null}
    {guide && (!guide.completed || searchParams.get('guide') === '1') ? <Guide onFinish={finishGuide} /> : null}
    {voiceOpen ? <VoiceMode onSend={sendMessage} onTranscribe={transcribeVoice} onClose={() => setVoiceOpen(false)} /> : null}
  </div>
}
