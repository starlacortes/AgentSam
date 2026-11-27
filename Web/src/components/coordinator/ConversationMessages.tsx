import { Fragment, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { EMPTY_CHAT_CARDS, type PromptCard } from '../../lib/promptCards'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../../api/client'
import type { AgentActionRequest, Conversation, ConversationMessage, MissionDetail } from '../../api/types'
import { dateLocale, useI18n } from '../../i18n'
import { replyLanguage, voiceTranscript } from '../../lib/coordinator'
import { Speaker } from '../../lib/voice'
import { isHTML, isPreviewableLanguage, pickEntry } from '../../lib/preview'
import { Markdown, type CodeTools } from '../Markdown'
import { ErrorBanner } from '../ui'
import { Icon } from './Icon'
import { InfoCards } from './InfoCards'
import type { CanvasState } from './SidePanel'
import { ThinkingIndicator, WorkSummary } from './ThinkingIndicator'
import { photoURL } from '../../lib/photos'

export function formatActionArguments(action: AgentActionRequest): string {
  const raw = action.arguments.raw
  if ((action.kind === 'connectorWrite' || action.kind === 'workstation' || action.kind === 'mcpCall' || action.kind === 'helperSave') && typeof raw === 'string') {
    try { return JSON.stringify(JSON.parse(raw), null, 2) } catch { return raw }
  }
  return JSON.stringify(action.arguments, null, 2)
}

/** True once an action can no longer change: it ran, was denied, failed, or expired. */
export function actionFinished(action: AgentActionRequest, now = Date.now()): boolean {
  if (action.status === 'pending') return Date.parse(action.expiresAt) <= now
  return action.status !== 'approved' && action.status !== 'executing'
}

/**
 * Places each action card after the last message that started at or before it, so newer
 * conversation flows below it instead of above. Returns, per message index, the actions
 * to show after it; index -1 holds actions older than every message.
 */
export function placeActions(messages: ConversationMessage[], actions: AgentActionRequest[]): Map<number, AgentActionRequest[]> {
  const placed = new Map<number, AgentActionRequest[]>()
  const sorted = [...actions].sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt))
  for (const action of sorted) {
    const at = Date.parse(action.createdAt)
    let index = -1
    messages.forEach((message, i) => { if (Date.parse(message.createdAt) <= at) index = i })
    placed.set(index, [...(placed.get(index) ?? []), action])
  }
  return placed
}

function autoChipLabel(action: AgentActionRequest, t: (key: string) => string): string {
  if (action.status === 'executing' || action.status === 'approved') return t('running automatically')
  if (action.status === 'failed') return t('failed')
  return t('ran automatically')
}

export function ActionApprovalCard({ action, onResolved, collapsed = false }: { action: AgentActionRequest; onResolved: (actions: AgentActionRequest[]) => void; collapsed?: boolean }) {
  const { t } = useI18n()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState<boolean | null>(null)
  const pending = action.status === 'pending'
  const expired = pending && Date.parse(action.expiresAt) <= Date.now()
  const decide = async (approve: boolean) => {
    setBusy(true)
    setError(null)
    try {
      onResolved(await api<AgentActionRequest[]>(`conversations/${action.conversationID}/actions/${action.id}`, { method: 'POST', body: { approve } }))
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const chip = <span className="co-chip">{expired ? t('expired') : action.automatic ? autoChipLabel(action, t) : t(action.status)}</span>
  // Cards that ran on a standing permission need nothing from the person, so they start folded,
  // even while running. Other finished cards fold once newer conversation arrives. Tapping opens them.
  const canFold = (action.automatic || actionFinished(action)) && !busy
  const expanded = !canFold || (open ?? !(collapsed || action.automatic))
  if (!expanded) return <section className="co-team-proposal co-action-card collapsed" aria-label={t('Action approval')}>
    <button type="button" className="co-action-summary" aria-expanded={false} onClick={() => setOpen(true)}>
      <Icon name="shield" size={14} /><b>{action.title}</b><span className="co-action-tool">{action.toolName}</span>{chip}<Icon name="chevron" size={13} />
    </button>
  </section>
  return <section className="co-team-proposal co-action-card" aria-label={t('Action approval')}>
    <div className="co-proposal-head"><Icon name="shield" /><div><b>{action.title}</b><span>{action.toolName}</span></div>{chip}
      {canFold ? <button type="button" className="co-action-fold" aria-expanded={true} aria-label={t('Collapse')} onClick={() => setOpen(false)}><Icon name="chevron" size={13} /></button> : null}
    </div>
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
  /** Opens the prompt cards list; with text, opens it ready to save that text as a new card. */
  onPromptCards?: (draft?: string) => void
}

function useCopy(): [boolean, (text: string) => void] {
  const [copied, setCopied] = useState(false)
  return [copied, (text: string) => { void navigator.clipboard?.writeText(text).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 1500) }) }]
}

/** One speaker for the whole chat, so starting a reply stops whichever one was playing. */
let sharedSpeaker: Speaker | null = null
let sharedOwner: ((playing: boolean) => void) | null = null

/** Stops any reply being read aloud, such as before voice mode opens the microphone. */
export function stopReadAloud(): void {
  sharedSpeaker?.stop()
  sharedOwner?.(false)
  sharedOwner = null
}

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
    // The whole reply is read, however long; the server splits it into pieces.
    sharedSpeaker.enqueue(voiceTranscript(message.speech ?? message.text, replyLanguage(message.speech ?? message.text, language)), `/api/conversations/${conversationID}/messages/${message.id}/speech?lang=${language}&chunk=0`)
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

function UserMessage({ conversationID, message, onEdit, onSave }: { conversationID: string; message: ConversationMessage; onEdit: (text: string) => void; onSave?: (text: string) => void }) {
  const { t } = useI18n()
  const [copied, copy] = useCopy()
  const photos = message.photos ?? []
  return <div className="co-user-message" title={timeLabel(message.createdAt)}>
    {photos.length ? <div className={`co-message-photos count-${Math.min(photos.length, 4)}`}>{photos.map((photo) => <a key={photo.id} href={photoURL(conversationID, photo.id)} target="_blank" rel="noreferrer" aria-label={t('Open photo')}><img src={photoURL(conversationID, photo.id)} alt={t('Attached photo')} loading="lazy" /></a>)}</div> : null}
    {message.scheduled ? <p className="co-scheduled-message"><span className="co-scheduled-tag"><Icon name="refresh" size={11} />{message.trigger ? t(message.trigger.kind === 'gmail' ? 'Started by a new email' : 'Started by a webhook call') : t('Scheduled run')}</span>{message.text}</p> : message.text || !photos.length ? <p>{message.text}</p> : null}
    <div className="co-user-actions"><button type="button" onClick={() => copy(message.text)} aria-label={t('Copy')}><Icon name={copied ? 'check' : 'copy'} size={11} /></button><button type="button" onClick={() => onEdit(message.text)} aria-label={t('Edit and resend')} title={t('Edit and resend')}><Icon name="edit" size={11} /></button>{onSave && message.text.trim() && !message.scheduled ? <button type="button" onClick={() => onSave(message.text)} aria-label={t('Save as prompt card')} title={t('Save as prompt card')}><Icon name="spark" size={11} /></button> : null}</div>
  </div>
}

function Message({ conversationID, message, latest, busy, handlers, retry, readAloud }: { conversationID: string; message: ConversationMessage; latest: boolean; busy: boolean; handlers: MessageHandlers; retry: () => void; readAloud: boolean }) {
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
  if (message.role === 'user') return <UserMessage conversationID={conversationID} message={message} onEdit={handlers.onEdit} onSave={handlers.onPromptCards} />
  const running = message.status === 'running'
  return <article className={`co-ada-message ${message.status}`}>
    <span className={`co-ada-avatar ${running ? 'working' : ''}`}>A</span>
    <div className="co-ada-content"><div className="co-ada-name">Ada{running ? <span>{t('Working')}</span> : null}{!running ? <time className="co-message-time" dateTime={message.createdAt}>{timeLabel(message.createdAt)}</time> : null}</div>
      {running ? <>{message.text ? <div className="co-response co-streaming"><Markdown source={message.text} codeTools={codeTools} /></div> : null}<ThinkingIndicator message={message} /></> : <><WorkSummary message={message} /><div className="co-response"><Markdown source={message.text} codeTools={codeTools} /></div></>}
      <InfoCards cards={message.cards} />
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
        {readAloud ? <button onClick={togglePlay} aria-pressed={playing}><Icon name={playing ? 'stop' : 'play'} size={12} />{playing ? t('Stop') : t('Play')}</button> : null}
        {latest ? <button onClick={retry} disabled={busy}><Icon name="retry" size={12} />{t('Retry')}</button> : null}
      </div> : null}
      {latest && message.status === 'complete' ? <QuickReplies replies={message.quickReplies ?? []} onPick={handlers.onQuickReply} disabled={busy} /> : null}
    </div>
  </article>
}

export function ConversationMessages({ conversation, busy = false, handlers, actions = [], onActions = () => {}, promptCards = [], readAloud = true, setup = null }: { conversation: Conversation | null; busy?: boolean; handlers: MessageHandlers; actions?: AgentActionRequest[]; onActions?: (actions: AgentActionRequest[]) => void; /** The person's saved prompts, shown on the empty chat in place of the built-in starters. */ promptCards?: PromptCard[]; /** False in voice mode, which reads replies itself: a second speaker would talk over Ada and into the microphone. */ readAloud?: boolean; /** The getting-started checklist, shown under the starters on the empty chat. */ setup?: ReactNode }) {
  const { t } = useI18n()
  const box = useRef<HTMLDivElement>(null)
  const pinned = useRef(true)
  const [away, setAway] = useState(false)
  const last = conversation?.messages.at(-1)
  useLayoutEffect(() => {
    const element = box.current
    if (element && pinned.current) element.scrollTop = element.scrollHeight
  }, [conversation?.messages.length, last?.status, last?.steps?.length, last?.text])
  // Stay at the latest message when the list's box changes size, such as under voice mode's orb.
  const hasMessages = Boolean(conversation?.messages.length)
  useEffect(() => {
    const element = box.current
    if (!element || typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(() => { if (pinned.current) element.scrollTop = element.scrollHeight })
    observer.observe(element)
    return () => observer.disconnect()
  }, [hasMessages])
  if (!conversation || (!conversation.messages.length && !actions.length)) return <div className="co-messages" ref={box}><div className="co-empty-chat"><span className="co-empty-orb">A</span><h1>{t('What can Ada help with?')}</h1><p>{t('Ask directly, or describe the outcome you need. Ada brings in specialists behind the scenes only when it helps.')}</p><div className="co-starters">
    {promptCards.length ? promptCards.slice(0, EMPTY_CHAT_CARDS).map((card) => <button key={card.id} className="co-prompt-card" onClick={() => handlers.onStarter(card.text)}><Icon name="spark" /><b>{card.title}</b><span>{card.text}</span></button>) : <>
      <button onClick={() => handlers.onStarter(t('What can you help me accomplish?'))}><Icon name="spark" /><b>{t('Start with a question')}</b><span>{t('Get a direct, concise answer.')}</span></button>
      <button onClick={() => handlers.onStarter(t('Build me a simple landing page for '))}><Icon name="monitor" /><b>{t('Build a web page')}</b><span>{t('Preview it live beside the chat as it takes shape.')}</span></button>
      <button onClick={() => handlers.onStarter(t('Whenever I ask for '))}><Icon name="plus" /><b>{t('Teach Ada a routine')}</b><span>{t('She remembers the steps and follows them next time.')}</span></button>
    </>}
  </div>{handlers.onPromptCards ? <button type="button" className="co-text-button co-prompt-manage" onClick={() => handlers.onPromptCards?.()}><Icon name={promptCards.length ? 'edit' : 'plus'} size={12} />{promptCards.length > EMPTY_CHAT_CARDS ? t('All {count} prompt cards', { count: String(promptCards.length) }) : promptCards.length ? t('Edit prompt cards') : t('Save your own prompt cards')}</button> : null}{setup}</div></div>
  const lastAssistant = conversation.messages.reduce((found, message, index) => message.role === 'assistant' ? index : found, -1)
  const placed = placeActions(conversation.messages, actions.slice(0, 10))
  const lastIndex = conversation.messages.length - 1
  // Collapse a finished card once a newer message sits below it.
  const cards = (index: number) => placed.get(index)?.map((action) => <ActionApprovalCard key={action.id} action={action} onResolved={onActions} collapsed={index < lastIndex} />)
  const jump = () => { const element = box.current; if (element) element.scrollTo({ top: element.scrollHeight, behavior: 'smooth' }) }
  return <div className="co-messages-wrap">
    <div className="co-messages" ref={box} onScroll={(event) => { const el = event.currentTarget; const near = el.scrollHeight - el.scrollTop - el.clientHeight < 70; pinned.current = near; setAway(!near) }}><div className="co-message-inner">
      {cards(-1)}
      {conversation.messages.map((message, index) => <Fragment key={message.id}>
        <Message conversationID={conversation.id} message={message} latest={index === lastAssistant} busy={busy} handlers={handlers} readAloud={readAloud} retry={() => { const previous = conversation.messages.slice(0, index).reverse().find((item) => item.role === 'user'); if (previous) handlers.onRetry(previous.text) }} />
        {cards(index)}
      </Fragment>)}
    </div></div>
    {away ? <button type="button" className="co-jump-latest" onClick={jump} aria-label={t('Jump to latest')}><Icon name="arrowDown" size={14} />{last?.status === 'running' ? t('Ada is working') : t('Latest')}</button> : null}
  </div>
}
