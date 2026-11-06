import { describe, expect, it } from 'vitest'
import type { Mission, RunEvent, Team } from '../api/types'
import { mergeEvents, parsePlan, presentMission } from './missionPresentation'

const agent = (id: string, name: string, role: 'coordinator' | 'worker' | 'verifier') => ({
  id, name, role, emoji: '', title: '', systemPrompt: '', providerID: 'p', model: 'm',
})
const team: Team = {
  id: 't', name: 'Team', emoji: '', goal: '', createdAt: '', updatedAt: '',
  agents: [agent('a0', 'Sam', 'coordinator'), agent('a1', 'Scout', 'worker'), agent('a2', 'Quill', 'worker'), agent('a3', 'Vera', 'verifier')],
}
const mission: Mission = {
  id: 'm', teamID: 't', teamName: 'Team', objective: 'x', status: 'running', phase: 'working',
  createdAt: '', totalCostUSD: 0, totalInputTokens: 0, totalOutputTokens: 0,
}
let seq = 0
const ev = (kind: RunEvent['kind'], extra: Partial<RunEvent> = {}): RunEvent => ({
  id: String(++seq), seq, missionID: 'm', timestamp: '2026-01-01T00:00:00Z', kind, ...extra,
})

const plan = 'Plan:\nTask 1 Research — Scout: Gather recent sources → sources.md\nTask 2 Draft — Quill: Write the brief → brief.md'

describe('parsePlan', () => {
  it('reads the TASK contract lines', () => {
    expect(parsePlan(plan)).toEqual([
      { number: 1, agentName: 'Scout', goal: 'Gather recent sources', deliverable: 'sources.md' },
      { number: 2, agentName: 'Quill', goal: 'Write the brief', deliverable: 'brief.md' },
    ])
  })
})

describe('presentMission', () => {
  it('tracks task and agent states from events', () => {
    seq = 0
    const events = [
      ev('plan', { text: plan }),
      ev('taskStarted', { agentName: 'Scout', text: 'Gather recent sources' }),
      ev('taskDone', { agentName: 'Scout', text: 'Found 5 sources' }),
      ev('taskStarted', { agentName: 'Quill', text: 'Write the brief' }),
      ev('notice', { text: 'Heads up' }),
    ]
    const p = presentMission(team, mission, events)
    expect(p.tasks.map((t) => t.state)).toEqual(['done', 'working'])
    expect(p.agents.map((a) => a.state)).toEqual(['idle', 'done', 'working', 'idle'])
    expect(p.chatter.map((c) => [c.text, c.system])).toEqual([
      ['Found 5 sources', false],
      ['Heads up', true],
    ])
  })

  it('marks everything done once the mission completes', () => {
    seq = 0
    const p = presentMission(team, { ...mission, status: 'completed', phase: 'done' }, [ev('plan', { text: plan })])
    expect(p.tasks.every((t) => t.state === 'done')).toBe(true)
    expect(p.agents.find((a) => a.agent.role === 'verifier')?.state).toBe('done')
  })
})

describe('mergeEvents', () => {
  it('dedupes by seq and sorts', () => {
    seq = 0
    const a = ev('notice')
    const b = ev('notice')
    expect(mergeEvents([b], [a, b]).map((e) => e.seq)).toEqual([1, 2])
  })
})
