import { useLayoutEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../../api/client'
import type { Conversation, ConversationMessage, TeamProposal } from '../../api/types'
import { useI18n } from '../../i18n'
import { canApprove } from '../../lib/coordinator'
import { Markdown } from '../Markdown'
import { ErrorBanner } from '../ui'
import { Icon } from './Icon'

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
  const permissions = [proposal.toolScope.permissions.sendEmail ? t('Send email') : null, proposal.toolScope.permissions.createDraft ? t('Create drafts') : null, proposal.toolScope.permissions.dnsWrite ? t('DNS writes') : null].filter(Boolean)
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

function Message({ conversationID, message, onUpdated, onRevise, onRetry }: { conversationID: string; message: ConversationMessage; onUpdated: (conversation: Conversation) => void; onRevise: () => void; onRetry: () => void }) {
  const { t } = useI18n()
  const [copied, setCopied] = useState(false)
  if (message.role === 'user') return <div className="co-user-message"><p>{message.text}</p></div>
  return <article className={`co-ada-message ${message.status}`}>
    <span className="co-ada-avatar">A</span>
    <div className="co-ada-content"><div className="co-ada-name">Ada <span>{message.status === 'running' ? t('Working') : t('Coordinator')}</span></div>
      {message.status === 'running' ? <div className="co-typing" role="status" aria-label={t('Ada is working')}><i /><i /><i /></div> : <div className="co-response"><Markdown source={message.text} /></div>}
      {message.status === 'failed' ? <button className="co-secondary-button co-retry" onClick={onRetry}>{t('Try again')}</button> : null}
      {message.missionIDs.length ? <div className="co-source-row">{message.missionIDs.map((id) => <Link key={id} className="co-source-chip" to={`/missions/${id}`}><Icon name="file" size={12} />{t('Work & files')}</Link>)}</div> : null}
      {message.proposal ? <ProposalCard conversationID={conversationID} message={message} onUpdated={onUpdated} onRevise={onRevise} /> : null}
      {message.status === 'complete' ? <div className="co-message-actions"><button onClick={() => { void navigator.clipboard?.writeText(message.text).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 1500) }) }}><Icon name={copied ? 'check' : 'copy'} size={12} />{copied ? t('Copied') : t('Copy')}</button></div> : null}
    </div>
  </article>
}

export function ConversationMessages({ conversation, onUpdated, onRevise, onRetry, onStarter }: { conversation: Conversation | null; onUpdated: (conversation: Conversation) => void; onRevise: () => void; onRetry: (text: string) => void; onStarter: (text: string) => void }) {
  const { t } = useI18n()
  const box = useRef<HTMLDivElement>(null)
  const pinned = useRef(true)
  useLayoutEffect(() => {
    const element = box.current
    if (element && pinned.current) element.scrollTop = element.scrollHeight
  }, [conversation?.messages.length, conversation?.messages.at(-1)?.status])
  if (!conversation?.messages.length) return <div className="co-messages" ref={box}><div className="co-empty-chat"><span className="co-empty-orb">A</span><h1>{t('What can Ada help with?')}</h1><p>{t('Ask directly, or describe the outcome you need. Ada will bring in a team only when it helps.')}</p><div className="co-starters">
    <button onClick={() => onStarter(t('What can you help me accomplish?'))}><Icon name="spark" /><b>{t('Start with a question')}</b><span>{t('Get a direct answer, without assembling a team.')}</span></button>
    <button onClick={() => onStarter(t('Help me plan a research project and summarize the findings.'))}><Icon name="users" /><b>{t('Put a team on a project')}</b><span>{t('Specialists work together; Ada brings you one result.')}</span></button>
    <button onClick={() => onStarter(t('Create a team for customer research and feedback analysis.'))}><Icon name="plus" /><b>{t('Describe your ideal team')}</b><span>{t('Ada proposes a roster for your approval.')}</span></button>
  </div></div></div>
  return <div className="co-messages" ref={box} onScroll={(event) => { const el = event.currentTarget; pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 70 }}><div className="co-message-inner">
    {conversation.messages.map((message, index) => <Message key={message.id} conversationID={conversation.id} message={message} onUpdated={onUpdated} onRevise={onRevise} onRetry={() => { const previous = conversation.messages.slice(0, index).reverse().find((item) => item.role === 'user'); if (previous) onRetry(previous.text) }} />)}
  </div></div>
}
