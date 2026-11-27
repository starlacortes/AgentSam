import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import type { AgentActivity, Conversation, ConversationMessage } from '../../api/types'
import { I18nProvider } from '../../i18n'
import { AgentWorkroom } from './AgentWorkroom'

const line = (agentName: string, state: string, summary: string, teamName?: string): AgentActivity =>
  ({ id: agentName, agentID: agentName, agentName, summary, state, updatedAt: '2026-01-01T00:00:00Z', teamName })

function chat(status: ConversationMessage['status'], activity: AgentActivity[]): Conversation {
  const message: ConversationMessage = { id: `m-${status}`, role: 'assistant', text: status === 'running' ? '' : 'Done.', createdAt: '2026-01-01T00:00:00Z', status, missionIDs: [], teamIDs: [], activity, steps: status === 'running' ? [{ id: 's', label: 'researchAda is working', state: 'working', startedAt: '2026-01-01T00:00:00Z' }] : [] }
  return { id: 'c', ownerID: 'o', title: 'Chat', projectName: 'Personal', createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z', running: status === 'running', messages: [message] }
}

afterEach(cleanup)

describe('work bar', () => {
  it('stays out of the way for a reply Ada wrote alone', () => {
    const { container } = render(<I18nProvider><AgentWorkroom conversation={chat('complete', [line('Ada', 'done', 'Answered')])} /></I18nProvider>)
    expect(container.innerHTML).toBe('')
  })

  it('says in plain words who is working, with helper details open while they work', () => {
    render(<I18nProvider><AgentWorkroom conversation={chat('running', [line('Ada', 'working', 'Answering'), line('researchAda', 'working', 'Find battery sources', 'Helper')])} /></I18nProvider>)
    expect(screen.getByText('Ada is working')).toBeTruthy()
    expect(screen.getByText('researchAda is working')).toBeTruthy()
    expect(screen.getByText('researchAda')).toBeTruthy()
    expect(screen.getByText('Find battery sources')).toBeTruthy()
    expect(screen.getByText('Working')).toBeTruthy()
  })

  it('folds a finished reply to one line that names the helpers', () => {
    render(<I18nProvider><AgentWorkroom conversation={chat('complete', [line('Ada', 'done', 'Answered'), line('judgeAda', 'done', 'PASS: figures check out', 'Helper')])} /></I18nProvider>)
    expect(screen.getByText('Ada had help from judgeAda')).toBeTruthy()
    expect(screen.queryByText('PASS: figures check out')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: /Details/ }))
    expect(screen.getByText('PASS: figures check out')).toBeTruthy()
  })
})

describe('work bar on a phone', () => {
  const original = window.matchMedia
  afterEach(() => { window.matchMedia = original })

  it('stays one line while specialists work, and opens on a tap', () => {
    window.matchMedia = ((query: string) => ({ matches: query.includes('max-width'), media: query, addEventListener() {}, removeEventListener() {} })) as unknown as typeof window.matchMedia
    render(<I18nProvider><AgentWorkroom conversation={chat('running', [line('Ada', 'working', 'Answering'), line('researchAda', 'working', 'Find battery sources', 'Helper')])} /></I18nProvider>)
    expect(screen.getByText('Ada is working')).toBeTruthy()
    expect(screen.getByText('1 specialist')).toBeTruthy()
    expect(screen.queryByText('Find battery sources')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: /Details/ }))
    expect(screen.getByText('Find battery sources')).toBeTruthy()
  })
})
