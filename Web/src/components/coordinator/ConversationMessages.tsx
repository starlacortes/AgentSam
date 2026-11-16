import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../../api/client'
import type { Conversation, ConversationMessage, MissionDetail, TeamProposal } from '../../api/types'
import { useI18n } from '../../i18n'
import { canApprove } from '../../lib/coordinator'
import { isHTML, isPreviewableLanguage, pickEntry } from '../../lib/preview'
import { Markdown, type CodeTools } from '../Markdown'
import { ErrorBanner } from '../ui'
import { Icon } from './Icon'
import type { CanvasState } from './SidePanel'
import { ThinkingIndicator, WorkSummary } from './ThinkingIndicator'

export function ProposalCard({ conversationID, message, onUpdated, onRevise }: { conversationID: string; message: ConversationMessage; onUpdated: (conversation: Conversation) => void; onRevise: () => void }) {
  const { t } = useI18n()
  const proposal = message.proposal as TeamProposal
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const act = async (action: 'apply' | 'dismiss') => {
    setBusy(true)
    setError(null)
    try {
      const result = await api<Conversation | { conversation: Conversation }>(`conversations/${conversationID}/proposals/${proposal.id}/${action}`, { method: 'POST' })
      onUpdated('conversation' in result ? result.conversation : result)
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const permissions = [proposal.toolScope.permissions.sendEmail ? t('Send email') : null, proposal.toolScope.permissions.createDraft ? t('Create drafts') : null, proposal.toolScope.permissions.dnsWrite ? t('DNS writes') : null, proposal.toolScope.permissions.githubWrite ? t('GitHub writes') : null].filter(Boolean)
  return <div className="co-team-proposal">
    <div className="co-proposal-head"><Icon name="users" /><div><b>{proposal.team.name}</b><span>{proposal.baseTeamID ? t('Team modification proposal') : t('New team proposal')}</span></div><span className="co-chip">{t(proposal.status)}</span></div>
    <p className="co-proposal-rationale">{proposal.rationale}</p>
    <div className="co-proposal-agents">{proposal.team.agents.map((agent) => <div key={agent.id}><span className="co-tiny-avatar">{agent.name[0]}</span><div><b>{agent.name} · {agent.title}</b><small>{t(agent.role)} · {agent.providerID}/{agent.model}</small></div></div>)}</div>
    <div className="co-proposal-permissions"><Icon name="shield" size={14} /><span>{proposal.toolScope.connectorIDs.length ? `${t('Connectors')}: ${proposal.toolScope.connectorIDs.join(', ')}` : t('No connector access')}{permissions.length ? ` · ${permissions.join(', ')}` : ` · ${t('Read only')}`}</span></div>
    {proposal.baseTeamID ? <p className="co-proposal-warning">{t('Approval updates this roster. Past missions and files are preserved.')}</p> : null}
    {proposal.status === 'applied' ? <Link className="co-text-link" to={`/teams/${proposal.team.id}`}>{t('Review the approved team')} →</Link> : null}
    {canApprove(message) ? <div className="co-proposal-actions"><button className="co-primary-button" disabled={busy} onClick={() => void act('apply')}><Icon name="check" size={14} />{t('Approve team')}</button><button className="co-secondary-button" disabled={busy} onClick={onRevise}>{t('Request changes')}</button><button className="co-secondary-button" disabled={busy} onClick={() => void act('dismiss')}>{t('Not now')}</button></div> : null}
    <ErrorBanner message={error} />
  </div>
}

export interface MessageHandlers {
  onUpdated: (conversation: Conversation) => void
  onRevise: () => void
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

function UserMessage({ message, onEdit }: { message: ConversationMessage; onEdit: (text: string) => void }) {
  const { t } = useI18n()
  const [copied, copy] = useCopy()
  return <div className="co-user-message" title={timeLabel(message.createdAt)}>
    {message.scheduled ? <p className="co-scheduled-message"><span className="co-scheduled-tag"><Icon name="refresh" size={11} />{t('Scheduled run')}</span>{message.text}</p> : <p>{message.text}</p>}
    <div className="co-user-actions"><button type="button" onClick={() => copy(message.text)} aria-label={t('Copy')}><Icon name={copied ? 'check' : 'copy'} size={11} /></button><button type="button" onClick={() => onEdit(message.text)} aria-label={t('Edit and resend')} title={t('Edit and resend')}><Icon name="edit" size={11} /></button></div>
  </div>
}

function Message({ conversationID, message, latest, busy, handlers, retry }: { conversationID: string; message: ConversationMessage; latest: boolean; busy: boolean; handlers: MessageHandlers; retry: () => void }) {
  const { t } = useI18n()
  const [copied, copy] = useCopy()
  const { onOpenCanvas } = handlers
  const codeTools = useMemo<CodeTools>(() => ({
    copyLabel: t('Copy'),
    copiedLabel: t('Copied'),
    previewLabel: t('Preview'),
    canPreview: isPreviewableLanguage,
    onPreview: (language, code) => onOpenCanvas({ tab: 'preview', source: { kind: 'code', title: language === 'svg' ? t('SVG from Ada') : t('Page from Ada'), language, code } }),
  }), [t, onOpenCanvas])
  if (message.role === 'user') return <UserMessage message={message} onEdit={handlers.onEdit} />
  const running = message.status === 'running'
  return <article className={`co-ada-message ${message.status}`}>
    <span className={`co-ada-avatar ${running ? 'working' : ''}`}>A</span>
    <div className="co-ada-content"><div className="co-ada-name">Ada <span>{running ? t('Working') : t('Coordinator')}</span>{!running ? <time className="co-message-time" dateTime={message.createdAt}>{timeLabel(message.createdAt)}</time> : null}</div>
      {running ? <ThinkingIndicator message={message} /> : <><WorkSummary message={message} /><div className="co-response"><Markdown source={message.text} codeTools={codeTools} /></div></>}
      {message.status === 'failed' ? <button className="co-secondary-button co-retry" onClick={retry}>{t('Try again')}</button> : null}
      {message.missionIDs.length ? <div className="co-source-row">
        {running ? <button type="button" className="co-source-chip co-watch-chip" onClick={() => onOpenCanvas({ tab: 'console', missionID: message.missionIDs[0], source: null })}><i className="co-live-dot" />{t('Watch work')}</button> : null}
        {message.missionIDs.map((id) => <Link key={id} className="co-source-chip" to={`/missions/${id}`}><Icon name="file" size={12} />{t('Work & files')}</Link>)}
        {!running ? message.missionIDs.map((id) => <SitePreviewChip key={`preview-${id}`} missionID={id} onOpen={(entry) => onOpenCanvas({ tab: 'preview', missionID: id, source: { kind: 'mission', missionID: id, entry } })} />) : null}
      </div> : null}
      {message.fileIDs?.length ? <div className="co-source-row">
        {message.fileIDs.map((name) => <button key={name} type="button" className="co-source-chip" onClick={() => onOpenCanvas({ tab: isHTML(name) ? 'preview' : 'files', source: { kind: 'chat', conversationID, entry: isHTML(name) ? name : undefined } })}><Icon name="file" size={12} />{name}</button>)}
      </div> : null}
      {message.proposal ? <ProposalCard conversationID={conversationID} message={message} onUpdated={handlers.onUpdated} onRevise={handlers.onRevise} /> : null}
      {message.status === 'complete' ? <div className="co-message-actions">
        <button onClick={() => copy(message.text)}><Icon name={copied ? 'check' : 'copy'} size={12} />{copied ? t('Copied') : t('Copy')}</button>
        {latest ? <button onClick={retry} disabled={busy}><Icon name="retry" size={12} />{t('Retry')}</button> : null}
      </div> : null}
      {latest && message.status === 'complete' ? <QuickReplies replies={message.quickReplies ?? []} onPick={handlers.onQuickReply} disabled={busy} /> : null}
    </div>
  </article>
}

export function ConversationMessages({ conversation, busy = false, handlers }: { conversation: Conversation | null; busy?: boolean; handlers: MessageHandlers }) {
  const { t } = useI18n()
  const box = useRef<HTMLDivElement>(null)
  const pinned = useRef(true)
  const [away, setAway] = useState(false)
  const last = conversation?.messages.at(-1)
  useLayoutEffect(() => {
    const element = box.current
    if (element && pinned.current) element.scrollTop = element.scrollHeight
  }, [conversation?.messages.length, last?.status, last?.steps?.length, last?.text])
  if (!conversation?.messages.length) return <div className="co-messages" ref={box}><div className="co-empty-chat"><span className="co-empty-orb">A</span><h1>{t('What can Ada help with?')}</h1><p>{t('Ask directly, or describe the outcome you need. Ada will bring in a team only when it helps.')}</p><div className="co-starters">
    <button onClick={() => handlers.onStarter(t('What can you help me accomplish?'))}><Icon name="spark" /><b>{t('Start with a question')}</b><span>{t('Get a direct answer, without assembling a team.')}</span></button>
    <button onClick={() => handlers.onStarter(t('Build me a simple landing page for '))}><Icon name="monitor" /><b>{t('Build a web page')}</b><span>{t('Preview it live beside the chat as it takes shape.')}</span></button>
    <button onClick={() => handlers.onStarter(t('Create a team for customer research and feedback analysis.'))}><Icon name="plus" /><b>{t('Describe your ideal team')}</b><span>{t('Ada proposes a roster for your approval.')}</span></button>
  </div></div></div>
  const lastAssistant = conversation.messages.reduce((found, message, index) => message.role === 'assistant' ? index : found, -1)
  const jump = () => { const element = box.current; if (element) element.scrollTo({ top: element.scrollHeight, behavior: 'smooth' }) }
  return <div className="co-messages-wrap">
    <div className="co-messages" ref={box} onScroll={(event) => { const el = event.currentTarget; const near = el.scrollHeight - el.scrollTop - el.clientHeight < 70; pinned.current = near; setAway(!near) }}><div className="co-message-inner">
      {conversation.messages.map((message, index) => <Message key={message.id} conversationID={conversation.id} message={message} latest={index === lastAssistant} busy={busy} handlers={handlers} retry={() => { const previous = conversation.messages.slice(0, index).reverse().find((item) => item.role === 'user'); if (previous) handlers.onRetry(previous.text) }} />)}
    </div></div>
    {away ? <button type="button" className="co-jump-latest" onClick={jump} aria-label={t('Jump to latest')}><Icon name="arrowDown" size={14} />{last?.status === 'running' ? t('Ada is working') : t('Latest')}</button> : null}
  </div>
}
