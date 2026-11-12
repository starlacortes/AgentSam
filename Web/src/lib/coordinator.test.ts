import { describe, expect, it } from 'vitest'
import type { AgentActivity, Conversation, ConversationMessage, Team } from '../api/types'
import { canApprove, connectorLabel, groupedConversations, presentWork, shouldPoll, voiceTranscript } from './coordinator'

const team: Team = { id: 'team-1', name: 'Research', emoji: 'R', goal: 'Research', agents: [], createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z' }
const activity: AgentActivity = { id: 'activity-1', agentID: 'agent-1', agentName: 'Scout', summary: 'Reviewing the brief', state: 'working', updatedAt: '2026-01-01T00:00:00Z', teamID: 'team-1' }

function message(status: ConversationMessage['status'], activities: AgentActivity[] = []): ConversationMessage {
  return { id: status, role: 'assistant', text: status === 'running' ? '' : 'One response from Ada', createdAt: '2026-01-01T00:00:00Z', status, missionIDs: [], teamIDs: activities.length ? ['team-1'] : [], activity: activities }
}

function conversation(messages: ConversationMessage[]): Conversation {
  return { id: 'chat-1', ownerID: 'owner', title: 'Project', projectName: 'Personal', createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z', running: false, messages }
}

describe('coordinator presentation', () => {
  it('shows the running team and resumes polling only while Ada works', () => {
    const running = conversation([message('running', [activity])])
    expect(presentWork(running, [team])).toMatchObject({ running: true, direct: false, teamNames: ['Research'], activities: [activity] })
    expect(shouldPoll(running)).toBe(true)
    expect(shouldPoll(conversation([message('complete')]))).toBe(false)
  })

  it('keeps the latest completed team visible after a direct response', () => {
    const direct = presentWork(conversation([message('complete'), message('complete')]), [team])
    expect(direct).toMatchObject({ running: false, direct: true, activities: [] })
    const earlier = conversation([message('complete', [{ ...activity, state: 'done' }])])
    expect(presentWork(earlier, []).teamNames).toEqual([])
  })

  it('groups chats by project without mutating their order', () => {
    const chats = [{ id: 'a', projectName: 'Launch' }, { id: 'b', projectName: 'Personal' }, { id: 'c', projectName: 'Launch' }, { id: 'd', projectName: ' ' }]
    expect(groupedConversations(chats).map(([name, items]) => [name, items.map((item) => item.id)])).toEqual([['Launch', ['a', 'c']], ['Personal', ['b', 'd']]])
  })

  it('describes Gmail configuration and availability distinctly', () => {
    const base = { id: 'gmail' as const, name: 'Gmail', detail: '', permissions: { sendEmail: false, createDraft: false, dnsWrite: false }, oauthAvailable: true }
    expect(connectorLabel(undefined)).toBe('Connect Gmail')
    expect(connectorLabel({ ...base, configured: false, enabled: true })).toBe('Connect Gmail')
    expect(connectorLabel({ ...base, configured: true, enabled: false })).toBe('Gmail off')
    expect(connectorLabel({ ...base, configured: true, enabled: true })).toBe('Gmail connected')
  })

  it('does not permit team mutation from a pending or failed response', () => {
    const complete = message('complete')
    const proposal = { id: 'proposal-1', team, rationale: 'A useful specialist', toolScope: { connectorIDs: [], permissions: { sendEmail: false, createDraft: false, dnsWrite: false } }, status: 'pending' as const, createdAt: '2026-01-01T00:00:00Z' }
    expect(canApprove({ ...complete, proposal })).toBe(true)
    expect(canApprove({ ...message('running'), proposal })).toBe(false)
    expect(canApprove({ ...complete, proposal: { ...proposal, status: 'applied' } })).toBe(false)
  })
})

describe('voice transcript', () => {
  it('speaks readable text rather than Markdown, code, or private activity', () => {
    expect(voiceTranscript('## Result\n**One answer.** [Read more](https://example.com)\n```swift\nsecret = 1\n```')).toBe('Result One answer. Read more Code example omitted from speech.')
    expect(voiceTranscript('Short answer')).toBe('Short answer')
  })
})
