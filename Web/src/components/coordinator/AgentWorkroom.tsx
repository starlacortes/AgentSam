import { useState } from 'react'
import type { AgentActivity, Team } from '../../api/types'
import { useI18n } from '../../i18n'
import { presentWork, type WorkPresentation } from '../../lib/coordinator'
import type { Conversation } from '../../api/types'
import { Icon } from './Icon'

const colors = ['emerald', 'teal', 'gold', 'sage']

function ActivityNode({ activity, index, compact }: { activity: AgentActivity; index: number; compact: boolean }) {
  const { t } = useI18n()
  return <div className={`co-agent-node ${activity.state}`} style={{ ['--agent-index' as string]: index % colors.length }}>
    <div className="co-agent-identity"><span className={`co-agent-avatar ${colors[index % colors.length]}`}>{activity.agentName.trim()[0]?.toUpperCase() ?? 'A'}<i /></span><div><b>{activity.agentName}</b><small>{activity.teamName ?? (activity.agentName === 'Ada' ? t('Coordinator') : t('Specialist'))}</small></div></div>
    {!compact ? <p className="co-agent-thought">{activity.summary}</p> : null}
  </div>
}

export function AgentWorkroom({ conversation, teams }: { conversation: Conversation | null; teams: Team[] }) {
  const { t } = useI18n()
  const [collapsed, setCollapsed] = useState(false)
  const presentation: WorkPresentation = presentWork(conversation, teams)
  const fallback: AgentActivity[] = [{ id: 'ada-ready', agentID: 'ada', agentName: 'Ada', summary: t('Ready to answer or find the right team'), state: 'idle', updatedAt: new Date().toISOString() }]
  const activities = presentation.activities.length ? presentation.activities : fallback
  const summary = presentation.running ? t('Work in progress') : presentation.teamNames.length ? t('Latest team activity') : t('Your workspace, one response')

  return <section className={`co-workroom ${collapsed ? 'collapsed' : ''}`} aria-label={t('Agent work summaries')} aria-description={t('These are short work summaries, not private agent reasoning.')}>
    <div className="co-workroom-head"><div className="co-workroom-title"><i className={presentation.running ? 'co-live-dot' : 'co-online-dot'} /><b>{t('Agent activity')}</b><span>{summary}</span></div><div className="co-workroom-meta"><span className="co-mini-chip">{t('Concise work summaries')}</span><button className="co-icon-button" aria-label={collapsed ? t('Expand agent activity') : t('Collapse agent activity')} aria-expanded={!collapsed} onClick={() => setCollapsed((value) => !value)}><Icon name="collapse" size={16} /></button></div></div>
    <div className="co-agent-graph">{activities.map((activity, index) => <ActivityNode key={`${activity.teamID ?? 'ada'}-${activity.agentID}-${index}`} activity={activity} index={index} compact={false} />)}</div>
    <div className="co-mobile-work">{activities.slice(0, 5).map((activity, index) => <ActivityNode key={`${activity.teamID ?? 'ada'}-${activity.agentID}-${index}`} activity={activity} index={index} compact />)}<p>{presentation.running ? activities.find((activity) => activity.state === 'working')?.summary : summary}</p></div>
  </section>
}
