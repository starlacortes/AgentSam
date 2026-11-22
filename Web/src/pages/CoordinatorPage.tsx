import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ClipboardEvent, type DragEvent, type FormEvent, type KeyboardEvent } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { api, errorMessage, uploadPhoto, uploadProjectFile } from '../api/client'
import type { AgentActionRequest, ArchiveSettings, ConnectorStatus, Conversation, ConversationSummary, GuideState, MissionDetail, ProviderStatus } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { AgentWorkroom } from '../components/coordinator/AgentWorkroom'
import { CoordinatorSidebar } from '../components/coordinator/CoordinatorSidebar'
import { ConversationMessages, type MessageHandlers } from '../components/coordinator/ConversationMessages'
import { SidePanel, type CanvasState } from '../components/coordinator/SidePanel'
import { ScheduleModal } from '../components/coordinator/ScheduleModal'
import { ArchivedChats, RetentionPrompt } from '../components/coordinator/ArchiveModals'
import { Guide } from '../components/coordinator/Guide'
import { Icon } from '../components/coordinator/Icon'
import { VoiceMode, type VoicePartial, type VoiceReply } from '../components/coordinator/VoiceMode'
import { PopMenu, type PopMenuItem } from '../components/coordinator/PopMenu'
import { ErrorBanner, Spinner } from '../components/ui'
import { useI18n } from '../i18n'
import { canvasForFinishedFiles, connectorLabel, pollDelay, shouldPoll, workspaceFileSource, wroteFreshFiles, browserTimeZone } from '../lib/coordinator'
import { pickEntry } from '../lib/preview'
import { isPhotoFile, MAX_PHOTOS, preparePhoto, type PendingPhoto } from '../lib/photos'
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
  const rest = list.filter((item) => item.id !== conversation.id)
  // An archived chat stays out of the sidebar even while it is open.
  if (conversation.archivedAt) return rest
  return [conversation, ...rest].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
}

export function CoordinatorPage() {
  const { id } = useParams()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const { t, lang } = useI18n()
  const { isAdmin } = useAuth()
  const [conversations, setConversations] = useState<ConversationSummary[]>([])
  const [conversation, setConversation] = useState<Conversation | null>(null)
  const [connectors, setConnectors] = useState<ConnectorStatus[]>([])
  const [providers, setProviders] = useState<ProviderStatus[]>([])
  const [guide, setGuide] = useState<GuideState | null>(null)
  const [draft, setDraft] = useState('')
  const [projectName, setProjectName] = useState('Personal')
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [voiceOpen, setVoiceOpen] = useState(false)
  const [scheduleOpen, setScheduleOpen] = useState(false)
  const [archiveSettings, setArchiveSettings] = useState<ArchiveSettings | null>(null)
  const [retentionFor, setRetentionFor] = useState<string | null>(null)
  const [archivedOpen, setArchivedOpen] = useState(false)
  const [archivedNotice, setArchivedNotice] = useState<{ id: string; title: string } | null>(null)
  const [loading, setLoading] = useState(true)
  const [sending, setSending] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [actions, setActions] = useState<AgentActionRequest[]>([])
  const [error, setError] = useState<string | null>(null)
  const [canvas, setCanvas] = useState<CanvasState | null>(null)
  const [canvasWidth, setCanvasWidth] = useState(() => Number(readStored(CANVAS_WIDTH_KEY)) || 520)
  const [dragging, setDragging] = useState(false)
  const [photos, setPhotos] = useState<PendingPhoto[]>([])
  const [preparing, setPreparing] = useState(0)
  const input = useRef<HTMLTextAreaElement>(null)
  const uploadInput = useRef<HTMLInputElement>(null)
  const cameraInput = useRef<HTMLInputElement>(null)
  const libraryInput = useRef<HTMLInputElement>(null)
  const photosRef = useRef<PendingPhoto[]>([])
  // On phones the photo button offers the camera or the library; elsewhere it opens the file picker.
  const touch = useMemo(() => typeof window.matchMedia === 'function' && window.matchMedia('(pointer: coarse)').matches, [])
  const draftKey = useRef<string>(`${DRAFT_PREFIX}new`)
  const carryDraft = useRef(false)
  const sendLock = useRef(false)
  const mounted = useRef(true)
  const running = shouldPoll(conversation)
  const hasProvider = providers.some((provider) => provider.hasKey)
  const gmail = connectors.find((connector) => connector.id === 'gmail')
  useDocumentTitle(conversation?.title ?? t('Chat'))
  // What Ada is doing right now (e.g. "Searching Gmail"), for the status box under the voice orb.
  const liveActivity = useMemo(() => {
    const reply = [...(conversation?.messages ?? [])].reverse().find((message) => message.status === 'running')
    if (!reply) return null
    return [...(reply.steps ?? [])].reverse().find((step) => step.state === 'working')?.label
      ?? reply.activity.find((item) => item.agentName === 'Ada' && item.state === 'working')?.summary
      ?? null
  }, [conversation?.messages])
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
    const chats = await api<ConversationSummary[]>('conversations')
    if (!mounted.current) return
    setConversations(chats)
  }, [])

  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  useEffect(() => { photosRef.current = photos }, [photos])
  // Thumbnails are object URLs; free them when the page goes away.
  useEffect(() => () => { for (const photo of photosRef.current) URL.revokeObjectURL(photo.url) }, [])

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const [chats, connectionList, providerList, guideState] = await Promise.all([
          api<ConversationSummary[]>('conversations'),
          api<ConnectorStatus[]>('connectors'),
          api<ProviderStatus[]>('providers'),
          api<GuideState>('workspace/guide'),
        ])
        if (!active) return
        setConversations(chats)
        setConnectors(connectionList)
        setProviders(providerList)
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
      if (event.key !== 'Escape' || !running || voiceOpen) return
      event.preventDefault()
      stopRef.current()
    }
    window.addEventListener('keydown', escape)
    return () => window.removeEventListener('keydown', escape)
  }, [running, voiceOpen])

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

  const sendMessage = async (raw: string, waitForCompletion = false, onPartial?: (update: VoicePartial) => void, includePhotos = false): Promise<VoiceReply | null> => {
    const text = raw.trim()
    // The composer and voice mode send the photos waiting in the composer; quick replies and retries don't.
    const attached = includePhotos || waitForCompletion ? photosRef.current : []
    if ((!text && !attached.length) || sendLock.current || (conversation && shouldPoll(conversation))) return null
    sendLock.current = true
    setSending(true)
    setError(null)
    try {
      const current = await ensureConversation()
      const photoIDs: string[] = []
      for (const photo of attached) photoIDs.push((await uploadPhoto(current.id, photo.blob)).id)
      const body = { text, language: lang, timeZone: browserTimeZone(), ...(photoIDs.length ? { photoIDs } : {}), ...(waitForCompletion ? { spoken: true } : {}) }
      const result = await api<Conversation>(`conversations/${current.id}/messages`, { method: 'POST', body })
      if (!mounted.current) return null
      replaceConversation(result)
      setDraft('')
      if (attached.length) {
        for (const photo of attached) URL.revokeObjectURL(photo.url)
        setPhotos((list) => list.filter((photo) => !attached.includes(photo)))
      }
      if (!waitForCompletion) return null
      for (let attempt = 0; attempt < 700; attempt += 1) {
        await new Promise((resolve) => window.setTimeout(resolve, attempt === 0 ? 150 : 200))
        if (!mounted.current) return null
        const next = await api<Conversation>(`conversations/${current.id}`)
        replaceConversation(next)
        const answer = next.messages.at(-1)
        if (answer && answer.role === 'assistant' && onPartial) {
          onPartial({ text: answer.text, speech: answer.speech, final: answer.status === 'complete', speechPath: `/api/conversations/${current.id}/speech?lang=${lang}` })
        }
        if (answer && answer.status !== 'running') {
          void refreshWorkspace()
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
    if (!preparing) void sendMessage(draft, false, undefined, true)
  }

  const composeKey = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault()
      if (!preparing) void sendMessage(draft, false, undefined, true)
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

  const addPhotos = async (files: File[]) => {
    const images = files.filter(isPhotoFile)
    if (!images.length) return
    const room = MAX_PHOTOS - photosRef.current.length
    if (images.length > room) setError(t('You can attach up to {count} photos to a message.', { count: MAX_PHOTOS }))
    const chosen = images.slice(0, Math.max(0, room))
    setPreparing((count) => count + chosen.length)
    for (const file of chosen) {
      try {
        const photo = await preparePhoto(file)
        if (!mounted.current || photosRef.current.length >= MAX_PHOTOS) { URL.revokeObjectURL(photo.url); continue }
        photosRef.current = [...photosRef.current, photo]
        setPhotos(photosRef.current)
      } catch {
        setError(t('{name} couldn’t be opened as a photo. Try a JPEG or PNG.', { name: file.name || t('That photo') }))
      } finally {
        if (mounted.current) setPreparing((count) => count - 1)
      }
    }
  }

  const removePhoto = (key: string) => {
    const photo = photosRef.current.find((item) => item.key === key)
    if (photo) URL.revokeObjectURL(photo.url)
    photosRef.current = photosRef.current.filter((item) => item.key !== key)
    setPhotos(photosRef.current)
  }

  const choosePhotos = (files: FileList | null) => {
    const list = [...(files ?? [])]
    if (list.length) void addPhotos(list)
  }

  const attach = async (files: FileList | File[]) => {
    const all = [...files]
    if (!all.length) return false
    // Photos become image attachments; text files are pasted into the message as before.
    void addPhotos(all.filter(isPhotoFile))
    const list = all.filter((file) => !isPhotoFile(file))
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
  }, [])

  const resizeCanvas = useCallback((width: number) => {
    const next = clampCanvasWidth(width)
    setCanvasWidth(next)
    writeStored(CANVAS_WIDTH_KEY, String(next))
  }, [])

  const prompt = (text: string) => {
    setDraft(text)
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
    if (!conversation || !window.confirm(t('Delete this conversation? Its messages will be removed; missions and files stay intact.'))) return
    try {
      await api(`conversations/${conversation.id}`, { method: 'DELETE' })
      setConversations((current) => current.filter((item) => item.id !== conversation.id))
      setConversation(null)
      navigate('/')
    } catch (err) { setError(errorMessage(err)) }
  }

  // Archive: the first time, ask how long archives are kept; then archive straight away.
  const archiveNow = async (chatID: string) => {
    try {
      const archived = await api<Conversation>(`conversations/${chatID}/archive`, { method: 'POST' })
      setConversations((current) => current.filter((item) => item.id !== chatID))
      setArchivedNotice({ id: chatID, title: archived.title })
      if (conversation?.id === chatID) {
        setConversation(null)
        navigate('/')
      }
    } catch (err) { setError(errorMessage(err)) }
  }

  const archiveChat = async (chatID: string) => {
    try {
      const settings = archiveSettings ?? await api<ArchiveSettings>('workspace/archive')
      setArchiveSettings(settings)
      if (settings.configured) await archiveNow(chatID)
      else setRetentionFor(chatID)
    } catch (err) { setError(errorMessage(err)) }
  }

  const restored = (chat: Conversation) => {
    setConversations((current) => mergeConversation(current, chat))
    setConversation((current) => current?.id === chat.id ? chat : current)
  }

  const undoArchive = async () => {
    const notice = archivedNotice
    if (!notice) return
    setArchivedNotice(null)
    try { restored(await api<Conversation>(`conversations/${notice.id}/archive`, { method: 'DELETE' })) } catch (err) { setError(errorMessage(err)) }
  }

  // The undo offer fades after a few seconds.
  useEffect(() => {
    if (!archivedNotice) return
    const timer = window.setTimeout(() => setArchivedNotice(null), 6000)
    return () => window.clearTimeout(timer)
  }, [archivedNotice])

  const finishGuide = async () => {
    const state = await api<GuideState>('workspace/guide', { method: 'PATCH', body: { completed: true } })
    setGuide(state)
    if (searchParams.has('guide')) setSearchParams({}, { replace: true })
  }

  const restartGuide = async () => {
    const state = await api<GuideState>('workspace/guide', { method: 'PATCH', body: { completed: false } })
    setGuide(state)
    setSearchParams({ guide: '1' })
  }

  const updateProposal = (next: Conversation) => {
    replaceConversation(next)
    void refreshWorkspace().catch((err) => setError(errorMessage(err)))
  }

  stopRef.current = () => { void stop() }

  const handlers: MessageHandlers = {
    onUpdated: updateProposal,
    onRetry: (text) => void sendMessage(text),
    onEdit: prompt,
    onQuickReply: (text) => void sendMessage(text),
    onOpenCanvas: openCanvas,
    onStarter: prompt,
  }

  function showArchived() {
    setArchivedOpen(true)
    if (!archiveSettings) void api<ArchiveSettings>('workspace/archive').then(setArchiveSettings).catch(() => {})
  }
  // Other pages link here with ?archived=1 to open the archived chats list.
  useEffect(() => {
    if (searchParams.get('archived') !== '1') return
    showArchived()
    setSearchParams({}, { replace: true })
  })

  // Less-used chat actions sit behind one "more" button so the header stays calm.
  const chatMenu: PopMenuItem[] = [
    ...(conversation && !conversation.schedule && !conversation.triggers?.length ? [{ label: t('Automate this chat'), icon: 'refresh' as const, disabled: running, onSelect: () => setScheduleOpen(true) }] : []),
    { label: t('Connections'), icon: 'plug', note: t(connectorLabel(gmail)), onSelect: () => navigate('/settings/connections') },
    { label: t('Open the guide'), icon: 'info', onSelect: () => void restartGuide().catch((err) => setError(errorMessage(err))) },
    ...(conversation ? [{ label: t('Delete conversation'), icon: 'trash' as const, danger: true, disabled: running, onSelect: () => void remove() }] : []),
  ]
  // One "+" for everything you can add: photos (camera on phones) and files for the project.
  const photosFull = running || photos.length + preparing >= MAX_PHOTOS
  const addMenu: PopMenuItem[] = [
    ...(touch ? [{ label: t('Take a photo'), icon: 'camera' as const, disabled: photosFull, onSelect: () => cameraInput.current?.click() }] : []),
    { label: touch ? t('Photo library') : t('Add photos'), icon: 'image', disabled: photosFull, onSelect: () => libraryInput.current?.click() },
    { label: t('Upload files to project'), icon: 'file', disabled: uploading, onSelect: () => uploadInput.current?.click() },
  ]

  return <div className={`co-app ${canvas ? 'with-canvas' : ''}`} style={canvas ? { ['--co-canvas-width' as string]: `${clampCanvasWidth(canvasWidth)}px` } : undefined}>
    <CoordinatorSidebar conversations={conversations} selectedID={conversation?.id ?? null} open={sidebarOpen} onClose={() => setSidebarOpen(false)} onSelect={(chatID) => navigate(`/chats/${chatID}`)} onNew={(project) => void newChat(project)} onArchive={(chatID) => void archiveChat(chatID)} onShowArchived={showArchived} archivedNotice={archivedNotice} onUndoArchive={() => void undoArchive()} />
    <main className="co-main">
      <header className="co-chat-header">
        <button className="co-icon-button co-menu-button" aria-label={t('Open workspace sidebar')} onClick={() => setSidebarOpen(true)}><Icon name="menu" /></button>
        <div className="co-chat-heading"><span>{t(conversation?.projectName ?? projectName)} <span className="co-path-separator">/</span></span><h1>{conversation?.title ?? t('New conversation')}</h1></div>
        <div className="co-header-actions">
          {conversation?.archivedAt ? <button className="co-archived-pill" title={t('Restore this chat to the sidebar')} onClick={() => void api<Conversation>(`conversations/${conversation.id}/archive`, { method: 'DELETE' }).then(restored).catch((err) => setError(errorMessage(err)))}><Icon name="archive" size={13} /><span>{t('Archived')}</span><b>{t('Restore')}</b></button> : null}
          {conversation?.schedule || conversation?.triggers?.length ? <button className="co-icon-button co-schedule-toggle active" aria-label={t('Automation on — open settings')} aria-pressed title={t('Automation')} onClick={() => setScheduleOpen(true)}><Icon name="refresh" size={16} /></button> : null}
          <button className={`co-icon-button co-canvas-toggle ${canvas ? 'active' : ''}`} aria-label={canvas ? t('Hide preview and console') : t('Show preview and console')} aria-pressed={Boolean(canvas)} title={t('Preview & console')} onClick={() => canvas ? setCanvas(null) : openCanvas({ tab: missionIDs.length ? 'console' : 'preview' })}><Icon name="panel" size={16} /></button>
          <button className="co-voice-button" onClick={() => setVoiceOpen(true)} disabled={sending}><Icon name="mic" size={15} /><span>{t('Voice')}</span></button>
          <PopMenu label={t('More chat options')} icon="more" className="co-chat-menu" items={chatMenu} />
        </div>
      </header>
      <AgentWorkroom conversation={conversation} />
      <div className="co-chat-body">
        {loading && id ? <div className="co-loading"><Spinner /></div> : <ConversationMessages conversation={conversation} busy={sending || running} handlers={handlers} actions={actions} onActions={setActions} />}
      </div>
      <div className="co-composer-wrap">
        {!hasProvider && !loading ? <div className="co-provider-notice"><Icon name="info" size={16} /><p>{t('Add a model provider and API key before chatting with Ada.')}</p>{isAdmin ? <Link to="/settings/providers">{t('Set up providers')} →</Link> : null}</div> : null}
        <ErrorBanner message={error} />
        <form className={`co-composer ${dragging ? 'dragging' : ''}`} onSubmit={submit} onDragOver={(event) => { if (event.dataTransfer.types.includes('Files')) { event.preventDefault(); setDragging(true) } }} onDragLeave={() => setDragging(false)} onDrop={drop}>
          <input ref={uploadInput} type="file" multiple hidden aria-label={t('Choose project files')} onChange={(event) => { const files = [...(event.currentTarget.files ?? [])]; event.currentTarget.value = ''; void upload(files) }} />
          <input ref={cameraInput} type="file" accept="image/*" capture="environment" hidden aria-label={t('Take a photo')} onChange={(event) => { const files = event.currentTarget.files; choosePhotos(files); event.currentTarget.value = '' }} />
          <input ref={libraryInput} type="file" accept="image/*" multiple hidden aria-label={t('Choose photos')} onChange={(event) => { const files = event.currentTarget.files; choosePhotos(files); event.currentTarget.value = '' }} />
          {dragging ? <div className="co-drop-hint"><Icon name="file" size={16} />{t('Drop photos or text files to add them to your message')}</div> : null}
          {photos.length || preparing ? <div className="co-photo-strip" role="group" aria-label={t('Attached photos')}>
            {photos.map((photo) => <div className="co-photo-thumb" key={photo.key}><img src={photo.url} alt={photo.name} /><button type="button" aria-label={t('Remove photo')} title={t('Remove photo')} onClick={() => removePhoto(photo.key)}><Icon name="close" size={11} /></button></div>)}
            {Array.from({ length: preparing }, (_, index) => <div className="co-photo-thumb preparing" key={`preparing-${index}`} role="status" aria-label={t('Preparing photo')}><span className="co-photo-spinner" /></div>)}
          </div> : null}
          <textarea ref={input} value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={composeKey} onPaste={paste} aria-label={t('Message Ada')} placeholder={t('Ask a question, or describe an outcome…')} rows={1} maxLength={20000} disabled={running} />
          <div className="co-composer-foot"><PopMenu label={t('Add photos or files')} icon={uploading ? 'refresh' : 'plus'} align="left" up className="co-add-menu" items={addMenu} /><span className="co-composer-spacer" />{running ? <button className="co-stop-button" type="button" onClick={() => void stop()} title={t('Stop (Esc)')}><Icon name="stop" size={12} />{t('Stop')}</button> : <button className="co-send-button" type="submit" aria-label={t('Send message')} disabled={sending || preparing > 0 || (!draft.trim() && !photos.length) || !hasProvider}><Icon name="arrow" size={18} /></button>}</div>
        </form>
      </div>
    </main>
    {canvas ? <SidePanel state={canvas} missionIDs={missionIDs} onChange={setCanvas} onClose={() => setCanvas(null)} onResize={resizeCanvas} /> : null}
    {retentionFor ? <RetentionPrompt onClose={() => setRetentionFor(null)} onChosen={(settings) => {
      const chatID = retentionFor
      setArchiveSettings(settings)
      setRetentionFor(null)
      void archiveNow(chatID)
    }} /> : null}
    {archivedOpen ? <ArchivedChats settings={archiveSettings} onSettings={setArchiveSettings} onRestored={restored} onClose={() => setArchivedOpen(false)} onOpen={(chatID) => { setArchivedOpen(false); navigate(`/chats/${chatID}`) }} /> : null}
    {scheduleOpen && conversation ? <ScheduleModal conversation={conversation} gmailConnected={Boolean(gmail?.configured)} onUpdated={updateProposal} onClose={() => setScheduleOpen(false)} /> : null}
    {guide && (!guide.completed || searchParams.get('guide') === '1') ? <Guide onFinish={finishGuide} /> : null}
    {voiceOpen ? <VoiceMode onSend={sendMessage} onTranscribe={transcribeVoice} onClose={() => setVoiceOpen(false)} activity={liveActivity} /> : null}
  </div>
}
