import { describe, expect, it } from 'vitest'
import type { AgentActivity, Conversation, ConversationMessage, Team } from '../api/types'
import { intervalLabel } from '../api/types'
import { canApprove, cappedSpeech, canvasForFinishedFiles, connectorLabel, groupedConversations, pollDelay, presentWork, shouldPoll, takeSpeakable, voiceTranscript, workspaceFileSource, wroteFreshFiles } from './coordinator'

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

  it('polls quickly only once the answer is streaming in', () => {
    expect(pollDelay(conversation([message('running', [activity])]))).toBe(900)
    expect(pollDelay(conversation([{ ...message('running', [activity]), text: 'Partial answer' }]))).toBe(250)
    expect(pollDelay(null)).toBe(900)
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
    const base = { id: 'gmail' as const, name: 'Gmail', detail: '', permissions: { sendEmail: false, createDraft: false, dnsWrite: false, githubWrite: false, adsWrite: false }, oauthAvailable: true }
    expect(connectorLabel(undefined)).toBe('Connect Gmail')
    expect(connectorLabel({ ...base, configured: false, enabled: true })).toBe('Connect Gmail')
    expect(connectorLabel({ ...base, configured: true, enabled: false })).toBe('Gmail off')
    expect(connectorLabel({ ...base, configured: true, enabled: true })).toBe('Gmail connected')
  })

  it('does not permit team mutation from a pending or failed response', () => {
    const complete = message('complete')
    const proposal = { id: 'proposal-1', team, rationale: 'A useful specialist', toolScope: { connectorIDs: [], permissions: { sendEmail: false, createDraft: false, dnsWrite: false, githubWrite: false, adsWrite: false } }, status: 'pending' as const, createdAt: '2026-01-01T00:00:00Z' }
    expect(canApprove({ ...complete, proposal })).toBe(true)
    expect(canApprove({ ...message('running'), proposal })).toBe(false)
    expect(canApprove({ ...complete, proposal: { ...proposal, status: 'applied' } })).toBe(false)
  })

  it('opens a page Ada wrote in the preview tab, and other files in the file list', () => {
    const complete = message('complete')
    expect(canvasForFinishedFiles(['index.html', 'notes.md'], complete)).toEqual({ tab: 'preview', entry: 'index.html' })
    expect(canvasForFinishedFiles(['site/about.html'], complete)).toEqual({ tab: 'preview', entry: 'site/about.html' })
    expect(canvasForFinishedFiles(['notes.md'], complete)).toEqual({ tab: 'files' })
    expect(canvasForFinishedFiles([], complete)).toBeNull()
    expect(canvasForFinishedFiles(['index.html'], message('running'))).toBeNull()
    expect(canvasForFinishedFiles(undefined, complete)).toBeNull()
    expect(wroteFreshFiles({ ...complete, fileIDs: ['index.html'] })).toBe(true)
    expect(wroteFreshFiles(complete)).toBe(false)
  })

  it('selects shared project files and keeps chat files in separate sources', () => {
    expect(workspaceFileSource('chat-1', ['project:index.html', 'project:styles.css', 'notes.md'])).toEqual({ kind: 'project', conversationID: 'chat-1', entry: 'index.html' })
    expect(workspaceFileSource('chat-1', ['notes.md', 'project:index.html'])).toEqual({ kind: 'chat', conversationID: 'chat-1', entry: undefined })
  })

  it('names the schedule intervals users can pick', () => {
    expect(intervalLabel(60)).toBe('hourly')
    expect(intervalLabel(1440)).toBe('daily')
    expect(intervalLabel(30)).toBe('every 30 minutes')
    expect(intervalLabel(45)).toBe('every 45 minutes')
  })
})

describe('voice transcript', () => {
  it('speaks readable text rather than Markdown, code, or private activity', () => {
    expect(voiceTranscript('## Result\n**One answer.** [Read more](https://example.com)\n```swift\nsecret = 1\n```')).toBe('Result. One answer. Read more Code example omitted from speech.')
    expect(voiceTranscript('Short answer')).toBe('Short answer')
  })
  it('follows the same rules as the server for links, IDs, paths, tables, lists and details', () => {
    const markdown = [
      'Saved to reports/q3/summary-final.md for follow-up, see https://example.com/a?b=1.',
      'Mission 3F2A9C1E-5B7D-4E8A-9C21-7D4E5F6A8B90 is done.',
      '| Name | Count |',
      '| --- | --- |',
      '| A | 1 |',
      'Back to talking.',
      '```details',
      'Everything here is for the screen.',
    ].join('\n')
    expect(voiceTranscript(markdown)).toBe('Saved to summary-final.md for follow-up, see the link on screen. Mission is done. The table is on screen. Back to talking.')
    expect(voiceTranscript('- first point\n- second point.')).toBe('first point. second point.')
  })
  it('caps long speech at a sentence end', () => {
    const long = 'This is a fairly ordinary sentence about nothing. '.repeat(20)
    const capped = cappedSpeech(long, 'The rest is on screen.')
    expect(capped.endsWith('nothing. The rest is on screen.')).toBe(true)
    expect(capped.length).toBeLessThanOrEqual(630)
    expect(cappedSpeech('Short.', 'x')).toBe('Short.')
  })
})

describe('takeSpeakable', () => {
  const first = 'Here is the first full sentence of the answer. '
  it('waits for a finished sentence while the reply is still streaming', () => {
    expect(takeSpeakable('Here is the first full sentence of the ans', 0, false)).toBeNull()
    const next = takeSpeakable(`${first}And the sec`, 0, false)
    expect(next?.text).toBe('Here is the first full sentence of the answer.')
    expect(takeSpeakable(`${first}And the sec`, next!.end, false)).toBeNull()
  })
  it('speaks the remainder once the reply is final, and skips code and suggestions', () => {
    const raw = `${first}Short.\n\`\`\`suggestions\nA\n\`\`\``
    const one = takeSpeakable(raw, 0, true)!
    const two = takeSpeakable(raw, one.end, true)
    expect(one.text).toBe('Here is the first full sentence of the answer.')
    expect(two?.text).toBe('Short.')
    expect(takeSpeakable(raw, two!.end, true)).toBeNull()
  })
  it('stops at the details line and announces a table once', () => {
    const raw = 'Here is the first full sentence of the answer.\n| a | b |\n| --- | --- |\n| 1 | 2 |\nThe last sentence is here too.\n```details\nScreen only.'
    const pieces: string[] = []
    for (let next = takeSpeakable(raw, 0, true), from = 0; next; next = takeSpeakable(raw, from, true)) {
      from = next.end
      pieces.push(next.text)
    }
    expect(pieces.join(' ')).toBe('Here is the first full sentence of the answer. The table is on screen. The last sentence is here too.')
  })
  it('never speaks a code block that is still open', () => {
    expect(takeSpeakable('Intro sentence that is long enough to be spoken. ```swift\nlet a = 1. ', 0, false)?.text).toBe('Intro sentence that is long enough to be spoken.')
  })
})

describe('takeSpeakable first piece', () => {
  const long = 'I went through the whole quarterly report this morning, compared it against last year’s numbers and the forecast you sent, and the short version is that revenue is up. '
  it('cuts a long opening sentence at a pause so speech starts sooner', () => {
    const one = takeSpeakable(long, 0, true)!
    expect(one.text).toBe('I went through the whole quarterly report this morning, compared it against last year’s numbers and the forecast you sent,')
    const two = takeSpeakable(long, one.end, true)!
    expect(two.text).toBe('and the short version is that revenue is up.')
  })
  it('can start a long opening sentence before it is finished', () => {
    const partial = long.slice(0, 150)
    expect(takeSpeakable(partial, 0, false)?.text).toBe('I went through the whole quarterly report this morning, compared it against last year’s numbers and the forecast you sent,')
  })
  it('leaves later sentences whole', () => {
    const first = 'Here is the first full sentence of the answer. '
    expect(takeSpeakable(first + long, first.length, true)?.text).toBe(long.trim())
  })
})
