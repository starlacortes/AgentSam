import { describe, expect, it } from 'vitest'
import type { AgentActivity, Conversation, ConversationMessage } from '../api/types'
import { intervalLabel } from '../api/types'
import { canvasForFinishedFiles, chatTitle, splitByToday, replyLanguage, connectorLabel, groupedConversations, pollDelay, presentWork, shouldPoll, takeSpeakable, voiceTranscript, workspaceFileSource, wroteFreshFiles } from './coordinator'

const activity: AgentActivity = { id: 'activity-1', agentID: 'agent-1', agentName: 'Scout', summary: 'Reviewing the brief', state: 'working', updatedAt: '2026-01-01T00:00:00Z', teamID: 'team-1', teamName: 'Research' }

function message(status: ConversationMessage['status'], activities: AgentActivity[] = []): ConversationMessage {
  return { id: status, role: 'assistant', text: status === 'running' ? '' : 'One response from Ada', createdAt: '2026-01-01T00:00:00Z', status, missionIDs: [], teamIDs: activities.length ? ['team-1'] : [], activity: activities }
}

function conversation(messages: ConversationMessage[]): Conversation {
  return { id: 'chat-1', ownerID: 'owner', title: 'Project', projectName: 'Personal', createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z', running: false, messages }
}

describe('chat list', () => {
  it('splits a project into chats from today and earlier ones', () => {
    const now = new Date(2026, 10, 27, 15, 0)
    const chats = [
      { id: 'a', updatedAt: new Date(2026, 10, 27, 9, 0).toISOString() },
      { id: 'b', updatedAt: new Date(2026, 10, 26, 23, 59).toISOString() },
      { id: 'c', updatedAt: new Date(2026, 10, 27, 0, 0).toISOString() },
    ]
    const { today, earlier } = splitByToday(chats, now)
    expect(today.map((chat) => chat.id)).toEqual(['a', 'c'])
    expect(earlier.map((chat) => chat.id)).toEqual(['b'])
  })

  it('translates only the untitled placeholder', () => {
    const t = (key: string) => (key === 'New conversation' ? 'Nueva conversación' : key)
    expect(chatTitle('New conversation', t)).toBe('Nueva conversación')
    expect(chatTitle(undefined, t)).toBe('Nueva conversación')
    expect(chatTitle('Taxes', t)).toBe('Taxes')
  })
})

describe('coordinator presentation', () => {
  it('shows the help Ada brought in and resumes polling only while Ada works', () => {
    const running = conversation([message('running', [activity])])
    expect(presentWork(running)).toMatchObject({ running: true, direct: false, helpNames: ['Research'], activities: [activity] })
    expect(shouldPoll(running)).toBe(true)
    expect(shouldPoll(conversation([message('complete')]))).toBe(false)
  })

  it('polls quickly only once the answer is streaming in', () => {
    expect(pollDelay(conversation([message('running', [activity])]))).toBe(900)
    expect(pollDelay(conversation([{ ...message('running', [activity]), text: 'Partial answer' }]))).toBe(250)
    expect(pollDelay(null)).toBe(900)
  })

  it('keeps the latest completed help visible after a direct response', () => {
    const direct = presentWork(conversation([message('complete'), message('complete')]))
    expect(direct).toMatchObject({ running: false, direct: true, activities: [] })
    const earlier = conversation([message('complete', [{ ...activity, state: 'done' }])])
    expect(presentWork(earlier).helpNames).toEqual(['Research'])
  })

  it('lists helpers and specialists, but not Ada, with plain states', () => {
    const helper: AgentActivity = { id: 'h1', agentID: 'h1', agentName: 'researchAda', summary: 'Find sources', state: 'working', updatedAt: '2026-01-01T00:00:00Z', teamName: 'Helper' }
    const ada: AgentActivity = { id: 'a1', agentID: 'ada', agentName: 'Ada', summary: 'Answering directly', state: 'working', updatedAt: '2026-01-01T00:00:00Z' }
    const running = { ...message('running', [ada, helper, { ...activity, state: 'idle' }]), steps: [{ id: 's1', label: 'researchAda is working', state: 'working' as const, startedAt: '2026-01-01T00:00:00Z' }] }
    const work = presentWork(conversation([running]))
    expect(work.now).toBe('researchAda is working')
    expect(work.helpers.map((item) => [item.name, item.helper, item.group, item.state])).toEqual([['researchAda', true, undefined, 'working'], ['Scout', false, 'Research', 'waiting']])
    expect(work.helpNames).toEqual(['Research'])
    expect(presentWork(conversation([message('complete')])).helpers).toEqual([])
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
  it('says what was skipped in Spanish for a Spanish reply', () => {
    expect(voiceTranscript('Aquí está.\n```js\nx = 1\n```\n| A | B |\n| --- | --- |\n| 1 | 2 |\nMira [la guía](https://example.com/guia) o https://example.com.', 'es'))
      .toBe('Aquí está. Hay un ejemplo de código en pantalla. La tabla está en pantalla. Mira la guía o el enlace en pantalla.')
  })
  it('tells the reply language from its prose, not its code or links', () => {
    expect(replyLanguage('Aquí está la tabla de precios.\n| A | B |\n| --- | --- |\n| 1 | 2 |', 'en')).toBe('es')
    expect(replyLanguage('Here is the fix for the build.\n```js\n// añadir la función de búsqueda para el menú\n```\nSee https://example.com/es/la-guía-del-menú', 'es')).toBe('en')
    expect(replyLanguage('OK', 'es')).toBe('es')
  })
  it('reads a very long reply in full', () => {
    const long = Array.from({ length: 400 }, (_, i) => `Point ${i + 1} is worth a sentence of its own.`).join(' ')
    let from = 0
    const pieces: string[] = []
    for (let next = takeSpeakable(long, from, true); next; next = takeSpeakable(long, from, true)) {
      from = next.end
      if (next.text) pieces.push(next.text)
    }
    expect(pieces.join(' ')).toBe(long)
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

describe('browserTimeZone', () => {
  it('returns the IANA zone the browser reports', async () => {
    const { browserTimeZone } = await import('./coordinator')
    expect(browserTimeZone()).toBe(Intl.DateTimeFormat().resolvedOptions().timeZone)
  })
})
