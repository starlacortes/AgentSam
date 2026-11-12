import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { api } from '../../api/client'
import type { Conversation, ConversationMessage, Team } from '../../api/types'
import { I18nProvider } from '../../i18n'
import { Guide } from './Guide'
import { ProposalCard } from './ConversationMessages'
import { WorkspacePanel } from './WorkspacePanels'

vi.mock('../../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../../api/client')>(), api: vi.fn() }))
vi.mock('../../auth/AuthContext', () => ({ useAuth: () => ({ me: { name: 'Owner' }, isAdmin: false, signOut: vi.fn() }) }))

const team: Team = {
  id: 'team-1', name: 'Customer research', emoji: 'R', goal: 'Understand customers', createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z',
  agents: [
    { id: 'ada-1', name: 'Ada', emoji: 'A', title: 'Coordinator', role: 'coordinator', systemPrompt: 'Coordinate', providerID: 'openai', model: 'gpt-test' },
    { id: 'scout-1', name: 'Scout', emoji: 'S', title: 'Researcher', role: 'worker', systemPrompt: 'Research', providerID: 'openai', model: 'gpt-test' },
  ],
}

function proposalMessage(status: ConversationMessage['status'] = 'complete'): ConversationMessage {
  return {
    id: 'message-1', role: 'assistant', text: 'Review this proposed team.', createdAt: '2026-01-01T00:00:00Z', status, missionIDs: [], teamIDs: [], activity: [],
    proposal: { id: 'proposal-1', team, rationale: 'A focused research team.', toolScope: { connectorIDs: [], permissions: { sendEmail: false, createDraft: false, dnsWrite: false } }, status: 'pending', createdAt: '2026-01-01T00:00:00Z' },
  }
}

function conversation(message: ConversationMessage): Conversation {
  return { id: 'chat-1', ownerID: 'owner', title: 'Team design', projectName: 'Personal', createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z', running: false, messages: [message] }
}

function renderUI(ui: React.ReactNode) {
  return render(<I18nProvider><MemoryRouter>{ui}</MemoryRouter></I18nProvider>)
}

describe('team proposal', () => {
  afterEach(() => { cleanup(); vi.clearAllMocks() })

  it('does not call a mutation API before approval and applies the exact proposal on approval', async () => {
    const message = proposalMessage()
    const updated = conversation({ ...message, proposal: { ...message.proposal!, status: 'applied' } })
    vi.mocked(api).mockResolvedValue({ conversation: updated })
    const onUpdated = vi.fn()
    renderUI(<ProposalCard conversationID="chat-1" message={message} onUpdated={onUpdated} onRevise={vi.fn()} />)
    expect(api).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Approve team' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('conversations/chat-1/proposals/proposal-1/apply', { method: 'POST' }))
    await waitFor(() => expect(onUpdated).toHaveBeenCalledWith(updated))
    expect(api).toHaveBeenCalledTimes(1)
  })

  it('cannot approve a team while its response is still running', () => {
    renderUI(<ProposalCard conversationID="chat-1" message={proposalMessage('running')} onUpdated={vi.fn()} onRevise={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Approve team' })).toBeNull()
    expect(api).not.toHaveBeenCalled()
  })
})

describe('resettable guide', () => {
  afterEach(() => { cleanup(); vi.clearAllMocks() })

  it('walks through three concise steps and completes only when dismissed', async () => {
    const finish = vi.fn().mockResolvedValue(undefined)
    renderUI(<Guide onFinish={finish} />)
    expect(screen.getByRole('heading', { name: 'One conversation. One clear answer.' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    expect(screen.getByText('Step 3 of 3')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Start chatting' }))
    await waitFor(() => expect(finish).toHaveBeenCalledTimes(1))
  })

  it('restarts the guide through its isolated preference action', async () => {
    const restart = vi.fn().mockResolvedValue(undefined)
    renderUI(<WorkspacePanel panel="settings" teams={[team]} connectors={[]} memory={null} onConnectors={vi.fn()} onMemory={vi.fn()} onClose={vi.fn()} onNewTeam={vi.fn()} onRestartGuide={restart} />)
    fireEvent.click(screen.getByRole('button', { name: 'Restart the guide' }))
    await waitFor(() => expect(restart).toHaveBeenCalledTimes(1))
    expect(api).not.toHaveBeenCalled()
  })
})
