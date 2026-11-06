import { describe, expect, it } from 'vitest'
import type { AgentProfile } from '../api/types'
import { teamWarnings } from './TeamEditPage'

const a = (name: string, role: AgentProfile['role']): AgentProfile => ({
  id: name, name, role, emoji: '', title: '', systemPrompt: '', providerID: 'anthropic', model: 'm',
})

describe('teamWarnings', () => {
  it('accepts a well-formed team', () => {
    expect(teamWarnings({ name: 'T', emoji: '', goal: '', agents: [a('Ada', 'coordinator'), a('Scout', 'worker'), a('Judge', 'verifier')] })).toEqual([])
  })
  it('flags missing coordinator and duplicate names', () => {
    const w = teamWarnings({ name: 'T', emoji: '', goal: '', agents: [a('Scout', 'worker'), a('scout', 'worker')] })
    expect(w).toContain('A team needs exactly one coordinator.')
    expect(w.some((x) => x.includes('unique'))).toBe(true)
  })
})
