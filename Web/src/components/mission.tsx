import type { AgentRole, MissionStatus } from '../api/types'
import type { AgentItem } from '../lib/missionPresentation'

export function StatusChip({ status }: { status: MissionStatus }) {
  return <span className={`chip status-${status}`}>{status}</span>
}

const roleTint: Record<AgentRole, string> = { coordinator: 'emerald', worker: 'teal', verifier: 'gold' }

export function Avatar({ name, role, size = 56, state }: { name: string; role?: AgentRole; size?: number; state?: AgentItem['state'] }) {
  const initial = (name.trim()[0] ?? '?').toUpperCase()
  return (
    <span
      className={`avatar ${role ? roleTint[role] : 'sage'} ${state ? `state-${state}` : ''}`}
      style={{ ['--s' as string]: `${size}px` }}
      aria-hidden="true"
    >
      {initial}
    </span>
  )
}

const stateLabel: Record<AgentItem['state'], string> = { idle: 'idle', working: 'working', done: 'done', failed: 'attention' }

/** Coordinator on top, workers across the middle, verifier at the bottom, like MissionStageView. */
export function AgentStage({ agents }: { agents: AgentItem[] }) {
  const rows: AgentItem[][] = [
    agents.filter((a) => a.agent.role === 'coordinator'),
    agents.filter((a) => a.agent.role === 'worker'),
    agents.filter((a) => a.agent.role === 'verifier'),
  ].filter((row) => row.length > 0)

  if (agents.length === 0) return null
  return (
    <div className="stage" aria-label="Agent stage">
      {rows.map((row, index) => (
        <div className="stage-row" key={index}>
          {row.map((item) => (
            <div className={`stage-node state-${item.state}`} key={item.agent.id} title={item.task ?? item.agent.title}>
              <Avatar name={item.agent.name} role={item.agent.role} state={item.state} />
              <b>{item.agent.name}</b>
              <span className="stage-state">{stateLabel[item.state]}</span>
              {item.state === 'working' && item.task ? <span className="stage-task">{item.task}</span> : null}
            </div>
          ))}
        </div>
      ))}
    </div>
  )
}

export function formatCost(usd: number): string {
  if (usd === 0) return '$0.00'
  if (usd < 0.01) return `$${usd.toFixed(4)}`
  return `$${usd.toFixed(2)}`
}

export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return String(n)
}
