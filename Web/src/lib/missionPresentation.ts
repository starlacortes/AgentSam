// Turns a mission's RunEvents into the
// task plan, agent stage states and team chatter the live view shows.
import type { AgentProfile, AgentRole, Mission, RunEvent, Team } from '../api/types'

export type TaskState = 'queued' | 'working' | 'done' | 'failed'
export type AgentState = 'idle' | 'working' | 'done' | 'failed'

export interface TaskItem {
  number: number
  agentName: string
  goal: string
  deliverable: string
  state: TaskState
}

export interface AgentItem {
  agent: AgentProfile
  state: AgentState
  task?: string
}

export interface ChatterItem {
  seq: number
  agentName?: string
  role?: AgentRole
  text: string
  timestamp: string
  system: boolean
  failed: boolean
}

export interface MissionPresentation {
  tasks: TaskItem[]
  agents: AgentItem[]
  chatter: ChatterItem[]
}

export function agentNamed(team: Team | undefined, name: string): AgentProfile | undefined {
  if (!team) return undefined
  const lower = name.trim().toLowerCase()
  return (
    team.agents.find((a) => a.name.toLowerCase() === lower) ??
    team.agents.find((a) => a.name.toLowerCase().includes(lower) || lower.includes(a.name.toLowerCase()))
  )
}

const TASK_LINE = /^Task (\d+) (.*)$/

export function parsePlan(plan: string): Omit<TaskItem, 'state'>[] {
  const result: Omit<TaskItem, 'state'>[] = []
  for (const raw of plan.split(/\r?\n/)) {
    const match = TASK_LINE.exec(raw.trim())
    if (!match) continue
    const number = Number(match[1])
    const parts = (match[2] ?? '').trim().split(' — ')
    if (parts.length < 2) continue
    const assignment = parts.slice(1).join(' — ')
    const colon = assignment.indexOf(':')
    if (colon < 0) continue
    const agentName = assignment.slice(0, colon).trim()
    const outputParts = assignment.slice(colon + 1).trim().split(' → ')
    const deliverable = outputParts.length > 1 ? (outputParts[outputParts.length - 1] ?? '').trim() : ''
    const goal = (outputParts.length > 1 ? outputParts.slice(0, -1) : outputParts).join(' → ').trim()
    if (!goal) continue
    result.push({ number, agentName, goal, deliverable })
  }
  return result
}

function matchesAgent(event: RunEvent, agentID: string | undefined, agentName: string): boolean {
  return (agentID !== undefined && event.agentID === agentID) || event.agentName === agentName
}

export function presentMission(team: Team | undefined, mission: Mission | undefined, rawEvents: RunEvent[]): MissionPresentation {
  const events = [...rawEvents].sort((a, b) => a.seq - b.seq)

  // Tasks
  const planEvent = [...events].reverse().find((e) => e.kind === 'plan')
  let tasks: TaskItem[] = planEvent?.text
    ? parsePlan(planEvent.text).map((item) => {
        const agentID = agentNamed(team, item.agentName)?.id
        const started = events.filter((e) => e.kind === 'taskStarted' && e.text === item.goal && matchesAgent(e, agentID, item.agentName))
        const firstStart = started[0]?.seq ?? Number.MAX_SAFE_INTEGER
        const after = (kind: RunEvent['kind']) =>
          events.some((e) => e.kind === kind && e.seq >= firstStart && matchesAgent(e, agentID, item.agentName))
        const state: TaskState = after('error') ? 'failed' : after('taskDone') ? 'done' : started.length > 0 ? 'working' : 'queued'
        return { ...item, state }
      })
    : []
  if (mission?.status === 'completed') {
    tasks = tasks.map((t) => (t.state === 'failed' ? t : { ...t, state: 'done' }))
  }

  // Agents
  const agents: AgentItem[] = (team?.agents ?? []).map((agent) => {
    const assigned = tasks.filter((t) => t.agentName === agent.name)
    let state: AgentState
    if (assigned.some((t) => t.state === 'failed')) state = 'failed'
    else if (assigned.some((t) => t.state === 'working')) state = 'working'
    else if (assigned.length > 0 && assigned.every((t) => t.state === 'done')) state = 'done'
    else if (mission?.status === 'running') {
      const key = `${agent.role}:${mission.phase}`
      if (['coordinator:planning', 'coordinator:reporting', 'verifier:verifying'].includes(key)) state = 'working'
      else if (key === 'verifier:reporting') state = 'done'
      else state = 'idle'
    } else if (mission?.phase === 'done' && (agent.role === 'coordinator' || agent.role === 'verifier')) {
      state = mission.status === 'failed' ? 'failed' : 'done'
    } else state = 'idle'
    const task = assigned.find((t) => t.state === 'working')?.goal ?? assigned[0]?.goal
    return { agent, state, task }
  })

  // Chatter
  const chatter: ChatterItem[] = []
  for (const event of events) {
    let system: boolean
    switch (event.kind) {
      case 'missionStart':
      case 'missionEnd':
      case 'notice':
      case 'error':
        system = true
        break
      case 'agentMessage':
      case 'taskDone':
      case 'verifyVerdict':
        system = false
        break
      default:
        continue
    }
    if (!event.text) continue
    const role = team?.agents.find((a) => a.id === event.agentID || a.name === event.agentName)?.role
    chatter.push({
      seq: event.seq,
      agentName: event.agentName,
      role,
      text: event.text,
      timestamp: event.timestamp,
      system,
      failed: event.kind === 'error',
    })
  }

  return { tasks, agents, chatter }
}

/** Merges new events into a list, de-duplicated by seq and kept in order. */
export function mergeEvents(existing: RunEvent[], incoming: RunEvent[]): RunEvent[] {
  if (incoming.length === 0) return existing
  const bySeq = new Map(existing.map((e) => [e.seq, e]))
  for (const e of incoming) bySeq.set(e.seq, e)
  return [...bySeq.values()].sort((a, b) => a.seq - b.seq)
}
