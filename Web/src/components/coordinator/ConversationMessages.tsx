import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../../api/client'
import type { AgentActionRequest, Conversation, ConversationMessage, MissionDetail } from '../../api/types'
import { dateLocale, useI18n } from '../../i18n'
import { cappedSpeech, voiceTranscript } from '../../lib/coordinator'
import { Speaker } from '../../lib/voice'
import { isHTML, isPreviewableLanguage, pickEntry } from '../../lib/preview'
import { Markdown, type CodeTools } from '../Markdown'
import { ErrorBanner } from '../ui'
import { Icon } from './Icon'
import type { CanvasState } from './SidePanel'
import { ThinkingIndicator, WorkSummary } from './ThinkingIndicator'
import { photoURL } from '../../lib/photos'

export function formatActionArguments(action: AgentActionRequest): string {
  const raw = action.arguments.raw
  if (action.kind === 'connectorWrite' && typeof raw === 'string') {
    try { return JSON.stringify(JSON.parse(raw), null, 2) } catch { return raw }
  }
  return JSON.stringify(action.arguments, null, 2)
}

export function ActionApprovalCard({ action, onResolved }: { action: AgentActionRequest; onResolved: (actions: AgentActionRequest[]) => void }) {
  const { t } = useI18n()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const pending = action.status === 'pending'
  const expired = pending && Date.parse(action.expiresAt) <= Date.now()
  const decide = async (approve: boolean) => {
    setBusy(true)
    setError(null)
    try {
      onResolved(await api<AgentActionRequest[]>(`conversations/${action.conversationID}/actions/${action.id}`, { method: 'POST', body: { approve } }))
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  return <section className="co-team-proposal co-action-card" aria-label={t('Action approval')}>
    <div className="co-proposal-head"><Icon name="shield" /><div><b>{action.title}</b><span>{action.toolName}</span></div><span className="co-chip">{expired ? t('expired') : t(action.status)}</span></div>
    <p className="co-proposal-rationale">{action.detail}</p>
    <pre className="co-action-arguments">{formatActionArguments(action)}</pre>
    {action.result ? <pre className="co-action-result">{action.result}</pre> : null}
    {pending ? <p className="co-proposal-warning">{expired ? t('This request has expired. No action was performed.') : t('Approval runs this action once. It expires {time}.', { time: new Date(action.expiresAt).toLocaleString(dateLocale()) })}</p> : null}
    {pending && !expired ? <div className="co-proposal-actions"><button className="co-primary-button" disabled={busy} onClick={() => void decide(true)}><Icon name="check" size={14} />{t('Approve once')}</button><button className="co-secondary-button" disabled={busy} onClick={() => void decide(false)}>{t('Deny')}</button></div> : null}
    <ErrorBanner message={error} />
  </section>
}

export interface MessageHandlers {
  onUpdated: (conversation: Conversation) => void
  onRetry: (text: string) => void
  onEdit: (text: string) => void
  onQuickReply: (text: string) => void
  onOpenCanvas: (state: Partial<CanvasState>) => void
  onStarter: (text: string) => void
}

function useCopy(): [boolean, (text: string) => void] {
  const [copied, setCopied] = useState(false)
  return [copied, (text: string) => { void navigator.clipboard?.writeText(text).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 1500) }) }]
}

/** One speaker for the whole chat, so starting a reply stops whichever one was playing. */
let sharedSpeaker: Speaker | null = null
let sharedOwner: ((playing: boolean) => void) | null = null

/** Reads a finished reply aloud with server speech, or the browser's voice when none is set up. */
function useReadAloud(conversationID: string, message: ConversationMessage, language: string): [boolean, () => void] {
  const [playing, setPlaying] = useState(false)
  const mine = useRef<(playing: boolean) => void>(setPlaying)
  useEffect(() => () => {
    if (sharedOwner === mine.current) { sharedSpeaker?.stop(); sharedOwner = null }
  }, [])
  return [playing, () => {
    if (playing) { sharedSpeaker?.stop(); return }
    sharedSpeaker ??= new Speaker(language === 'es' ? 'es-ES' : 'en-US')
    sharedSpeaker.stop()
    sharedOwner?.(false)
    sharedOwner = mine.current
    sharedSpeaker.onChange = (speaking) => { sharedOwner?.(speaking) }
    sharedSpeaker.unlock()
    const tail = language === 'es' ? 'El resto está en pantalla.' : 'The rest is on screen.'
    sharedSpeaker.enqueue(cappedSpeech(voiceTranscript(message.speech ?? message.text), tail), `/api/conversations/${conversationID}/messages/${message.id}/speech?lang=${language}&chunk=0`)
  }]
}

function timeLabel(iso: string): string {
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? '' : date.toLocaleString([], { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' })
}

/** Shows "Preview site" once a finished mission has written an HTML page. */
function SitePreviewChip({ missionID, onOpen }: { missionID: string; onOpen: (entry: string) => void }) {
  const { t } = useI18n()
  const [entry, setEntry] = useState<string | null>(null)
  useEffect(() => {
    let active = true
    void api<MissionDetail>(`missions/${missionID}`).then((detail) => { if (active) setEntry(pickEntry(detail.deliverables)) }).catch(() => {})
    return () => { active = false }
  }, [missionID])
  if (!entry) return null
  return <button type="button" className="co-source-chip co-preview-chip" onClick={() => onOpen(entry)}><Icon name="monitor" size={12} />{t('Preview site')}</button>
}

export function QuickReplies({ replies, onPick, disabled }: { replies: string[]; onPick: (text: string) => void; disabled?: boolean }) {
  const { t } = useI18n()
  if (!replies.length) return null
  return <div className="co-quick-replies" role="group" aria-label={t('Suggested replies')}>{replies.map((reply) => <button key={reply} type="button" disabled={disabled} onClick={() => onPick(reply)}>{reply}</button>)}</div>
}

function UserMessage({ conversationID, message, onEdit }: { conversationID: string; message: ConversationMessage; onEdit: (text: string) => void }) {
  const { t } = useI18n()
  const [copied, copy] = useCopy()
  const photos = message.photos ?? []
  return <div className="co-user-message" title={timeLabel(message.createdAt)}>
    {photos.length ? <div className={`co-message-photos count-${Math.min(photos.length, 4)}`}>{photos.map((photo) => <a key={photo.id} href={photoURL(conversationID, photo.id)} target="_blank" rel="noreferrer" aria-label={t('Open photo')}><img src={photoURL(conversationID, photo.id)} alt={t('Attached photo')} loading="lazy" /></a>)}</div> : null}
    {message.scheduled ? <p className="co-scheduled-message"><span className="co-scheduled-tag"><Icon name="refresh" size={11} />{t('Scheduled run')}</span>{message.text}</p> : message.text || !photos.length ? <p>{message.text}</p> : null}
    <div className="co-user-actions"><button type="button" onClick={() => copy(message.text)} aria-label={t('Copy')}><Icon name={copied ? 'check' : 'copy'} size={11} /></button><button type="button" onClick={() => onEdit(message.text)} aria-label={t('Edit and resend')} title={t('Edit and resend')}><Icon name="edit" size={11} /></button></div>
  </div>
}

function Message({ conversationID, message, latest, busy, handlers, retry }: { conversationID: string; message: ConversationMessage; latest: boolean; busy: boolean; handlers: MessageHandlers; retry: () => void }) {
  const { t, lang } = useI18n()
  const [copied, copy] = useCopy()
  const [playing, togglePlay] = useReadAloud(conversationID, message, lang)
  const { onOpenCanvas } = handlers
  const codeTools = useMemo<CodeTools>(() => ({
    copyLabel: t('Copy'),
    copiedLabel: t('Copied'),
    previewLabel: t('Preview'),
    canPreview: isPreviewableLanguage,
    onPreview: (language, code) => onOpenCanvas({ tab: 'preview', source: { kind: 'code', title: language === 'svg' ? t('SVG from Ada') : t('Page from Ada'), language, code } }),
  }), [t, onOpenCanvas])
  if (message.role === 'user') return <UserMessage conversationID={conversationID} message={message} onEdit={handlers.onEdit} />
  const running = message.status === 'running'
  return <article className={`co-ada-message ${message.status}`}>
    <span className={`co-ada-avatar ${running ? 'working' : ''}`}>A</span>
    <div className="co-ada-content"><div className="co-ada-name">Ada <span>{running ? t('Working') : t('Coordinator')}</span>{!running ? <time className="co-message-time" dateTime={message.createdAt}>{timeLabel(message.createdAt)}</time> : null}</div>
      {running ? <>{message.text ? <div className="co-response co-streaming"><Markdown source={message.text} codeTools={codeTools} /></div> : null}<ThinkingIndicator message={message} /></> : <><WorkSummary message={message} /><div className="co-response"><Markdown source={message.text} codeTools={codeTools} /></div></>}
      {message.status === 'failed' ? <button className="co-secondary-button co-retry" onClick={retry}>{t('Try again')}</button> : null}
      {message.missionIDs.length ? <div className="co-source-row">
        {running ? <button type="button" className="co-source-chip co-watch-chip" onClick={() => onOpenCanvas({ tab: 'console', missionID: message.missionIDs[0], source: null })}><i className="co-live-dot" />{t('Watch work')}</button> : null}
        {message.missionIDs.map((id) => <Link key={id} className="co-source-chip" to={`/missions/${id}`}><Icon name="file" size={12} />{t('Work & files')}</Link>)}
        {!running ? message.missionIDs.map((id) => <SitePreviewChip key={`preview-${id}`} missionID={id} onOpen={(entry) => onOpenCanvas({ tab: 'preview', missionID: id, source: { kind: 'mission', missionID: id, entry } })} />) : null}
      </div> : null}
      {message.fileIDs?.length ? <div className="co-source-row">
        {message.fileIDs.map((name) => {
          const project = name.startsWith('project:')
          const entry = name.replace(/^project:/, '')
          return <button key={name} type="button" className="co-source-chip" onClick={() => onOpenCanvas({ tab: isHTML(name) ? 'preview' : 'files', source: { kind: project ? 'project' : 'chat', conversationID, entry: isHTML(name) ? entry : undefined } })}><Icon name="file" size={12} />{name}</button>
        })}
      </div> : null}
      {message.status === 'complete' ? <div className="co-message-actions">
        <button onClick={() => copy(message.text)}><Icon name={copied ? 'check' : 'copy'} size={12} />{copied ? t('Copied') : t('Copy')}</button>
        <button onClick={togglePlay} aria-pressed={playing}><Icon name={playing ? 'stop' : 'play'} size={12} />{playing ? t('Stop') : t('Play')}</button>
        {latest ? <button onClick={retry} disabled={busy}><Icon name="retry" size={12} />{t('Retry')}</button> : null}
      </div> : null}
      {latest && message.status === 'complete' ? <QuickReplies replies={message.quickReplies ?? []} onPick={handlers.onQuickReply} disabled={busy} /> : null}
    </div>
  </article>
}

export function ConversationMessages({ conversation, busy = false, handlers, actions = [], onActions = () => {} }: { conversation: Conversation | null; busy?: boolean; handlers: MessageHandlers; actions?: AgentActionRequest[]; onActions?: (actions: AgentActionRequest[]) => void }) {
  const { t } = useI18n()
  const box = useRef<HTMLDivElement>(null)
  const pinned = useRef(true)
  const [away, setAway] = useState(false)
  const last = conversation?.messages.at(-1)
  useLayoutEffect(() => {
    const element = box.current
    if (element && pinned.current) element.scrollTop = element.scrollHeight
  }, [conversation?.messages.length, last?.status, last?.steps?.length, last?.text])
  if (!conversation || (!conversation.messages.length && !actions.length)) return <div className="co-messages" ref={box}><div className="co-empty-chat"><span className="co-empty-orb">A</span><h1>{t('What can Ada help with?')}</h1><p>{t('Ask directly, or describe the outcome you need. Ada brings in specialists behind the scenes only when it helps.')}</p><div className="co-starters">
    <button onClick={() => handlers.onStarter(t('What can you help me accomplish?'))}><Icon name="spark" /><b>{t('Start with a question')}</b><span>{t('Get a direct, concise answer.')}</span></button>
    <button onClick={() => handlers.onStarter(t('Build me a simple landing page for '))}><Icon name="monitor" /><b>{t('Build a web page')}</b><span>{t('Preview it live beside the chat as it takes shape.')}</span></button>
    <button onClick={() => handlers.onStarter(t('Whenever I ask for '))}><Icon name="plus" /><b>{t('Teach Ada a routine')}</b><span>{t('She remembers the steps and follows them next time.')}</span></button>
  </div></div></div>
  const lastAssistant = conversation.messages.reduce((found, message, index) => message.role === 'assistant' ? index : found, -1)
  const jump = () => { const element = box.current; if (element) element.scrollTo({ top: element.scrollHeight, behavior: 'smooth' }) }
  return <div className="co-messages-wrap">
    <div className="co-messages" ref={box} onScroll={(event) => { const el = event.currentTarget; const near = el.scrollHeight - el.scrollTop - el.clientHeight < 70; pinned.current = near; setAway(!near) }}><div className="co-message-inner">
      {conversation.messages.map((message, index) => <Message key={message.id} conversationID={conversation.id} message={message} latest={index === lastAssistant} busy={busy} handlers={handlers} retry={() => { const previous = conversation.messages.slice(0, index).reverse().find((item) => item.role === 'user'); if (previous) handlers.onRetry(previous.text) }} />)}
      {actions.slice(0, 10).map((action) => <ActionApprovalCard key={action.id} action={action} onResolved={onActions} />)}
    </div></div>
    {away ? <button type="button" className="co-jump-latest" onClick={jump} aria-label={t('Jump to latest')}><Icon name="arrowDown" size={14} />{last?.status === 'running' ? t('Ada is working') : t('Latest')}</button> : null}
  </div>
}
