import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { api } from '../../api/client'
import type { AgentActionRequest, Conversation, ConversationMessage, WorkspaceKnowledge } from '../../api/types'
import { I18nProvider } from '../../i18n'
import { Guide } from './Guide'
import { ActionApprovalCard, ConversationMessages } from './ConversationMessages'
import { WorkspacePanel } from './WorkspacePanels'

vi.mock('../../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../../api/client')>(), api: vi.fn() }))
vi.mock('../../auth/AuthContext', () => ({ useAuth: () => ({ me: { name: 'Owner' }, isAdmin: false, signOut: vi.fn() }) }))

const knowledge: WorkspaceKnowledge = {
  status: 'ready', refreshCount: 1, updatedAt: '2026-01-01T00:00:00Z',
  documents: [
    { id: 'capabilities', title: 'Workspace capabilities', markdown: '# Workspace capabilities\n- web_fetch', updatedAt: '2026-01-01T00:00:00Z' },
    { id: 'connections', title: 'Workspace connections', markdown: '# Workspace connections\n- Gmail: not connected', updatedAt: '2026-01-01T00:00:00Z' },
    { id: 'projects', title: 'Workspace projects', markdown: '# Workspace projects\n- Launch', updatedAt: '2026-01-01T00:00:00Z' },
  ],
}

function conversation(message: ConversationMessage): Conversation {
  return { id: 'chat-1', ownerID: 'owner', title: 'Team design', projectName: 'Personal', createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z', running: false, messages: [message] }
}

function renderUI(ui: React.ReactNode) {
  return render(<I18nProvider><MemoryRouter>{ui}</MemoryRouter></I18nProvider>)
}

describe('no team setup in chat', () => {
  afterEach(() => { cleanup(); vi.clearAllMocks() })

  it('offers no team starter and never shows a team proposal card', () => {
    const message: ConversationMessage = { id: 'm1', role: 'assistant', text: 'Here is the answer.', createdAt: '2026-01-01T00:00:00Z', status: 'complete', missionIDs: [], teamIDs: [], activity: [] }
    const handlers = { onUpdated: vi.fn(), onRetry: vi.fn(), onEdit: vi.fn(), onQuickReply: vi.fn(), onOpenCanvas: vi.fn(), onStarter: vi.fn() }
    renderUI(<ConversationMessages conversation={null} busy={false} handlers={handlers} actions={[]} onActions={vi.fn()} />)
    expect(screen.queryByText(/team/i)).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: /Teach Ada a routine/ }))
    expect(handlers.onStarter).toHaveBeenCalledWith('Whenever I ask for ')
    cleanup()
    renderUI(<ConversationMessages conversation={conversation(message)} busy={false} handlers={handlers} actions={[]} onActions={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Approve team' })).toBeNull()
  })
})

describe('action approvals', () => {
  afterEach(() => { cleanup(); vi.clearAllMocks() })

  const action: AgentActionRequest = {
    id: 'action-1', ownerID: 'owner', conversationID: 'chat-1', kind: 'connectorWrite',
    title: 'Create DNS record?', detail: 'Create this record only after approval.', toolName: 'cloudflare_dns_create',
    arguments: { raw: '{"zone_id":"example.test","type":"TXT","name":"status","content":"ready"}' },
    status: 'pending', createdAt: '2026-01-01T00:00:00Z', expiresAt: new Date(Date.now() + 60_000).toISOString(),
  }

  it('shows exact arguments and executes an approval only once', async () => {
    const resolved = { ...action, status: 'completed' as const, result: 'Created DNS record.' }
    vi.mocked(api).mockResolvedValue([resolved])
    const onResolved = vi.fn()
    renderUI(<ActionApprovalCard action={action} onResolved={onResolved} />)
    expect(api).not.toHaveBeenCalled()
    expect(screen.getByText(/"zone_id": "example.test"/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Approve once' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('conversations/chat-1/actions/action-1', { method: 'POST', body: { approve: true } }))
    await waitFor(() => expect(onResolved).toHaveBeenCalledWith([resolved]))
    expect(api).toHaveBeenCalledTimes(1)
  })

  it('denies without running the connector operation', async () => {
    const resolved = { ...action, status: 'denied' as const }
    vi.mocked(api).mockResolvedValue([resolved])
    const onResolved = vi.fn()
    renderUI(<ActionApprovalCard action={action} onResolved={onResolved} />)
    fireEvent.click(screen.getByRole('button', { name: 'Deny' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('conversations/chat-1/actions/action-1', { method: 'POST', body: { approve: false } }))
    await waitFor(() => expect(onResolved).toHaveBeenCalledWith([resolved]))
    expect(api).toHaveBeenCalledTimes(1)
  })

  it('does not offer approval for an expired or completed action', () => {
    renderUI(<ActionApprovalCard action={{ ...action, expiresAt: '2020-01-01T00:00:00Z' }} onResolved={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Approve once' })).toBeNull()
    cleanup()
    renderUI(<ActionApprovalCard action={{ ...action, status: 'completed', result: 'Done' }} onResolved={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Approve once' })).toBeNull()
    expect(api).not.toHaveBeenCalled()
  })
})

describe('workspace knowledge', () => {
  afterEach(() => { cleanup(); vi.clearAllMocks() })

  it('shows maintained documents, switches tabs, and refreshes on request', async () => {
    vi.mocked(api).mockResolvedValue(knowledge)
    const onKnowledge = vi.fn()
    renderUI(<WorkspacePanel panel="knowledge" connectors={[]} memory={null} knowledge={knowledge} onConnectors={vi.fn()} onMemory={vi.fn()} onKnowledge={onKnowledge} onClose={vi.fn()} onRestartGuide={vi.fn()} />)
    expect(screen.getByText(/# Workspace capabilities/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Connections' }))
    expect(screen.getByText(/# Workspace connections/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Refresh now' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('workspace/knowledge/refresh', { method: 'POST' }))
    await waitFor(() => expect(onKnowledge).toHaveBeenCalledWith(knowledge))
    expect(screen.getByRole('link', { name: 'Export connections.md' }).getAttribute('href')).toBe('/api/workspace/knowledge/connections/export')
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
    renderUI(<WorkspacePanel panel="settings" connectors={[]} memory={null} knowledge={null} onConnectors={vi.fn()} onMemory={vi.fn()} onKnowledge={vi.fn()} onClose={vi.fn()} onRestartGuide={restart} />)
    fireEvent.click(screen.getByRole('button', { name: 'Restart the guide' }))
    await waitFor(() => expect(restart).toHaveBeenCalledTimes(1))
    expect(api).not.toHaveBeenCalled()
  })
})

describe('photos in messages', () => {
  it('shows attached photos above the text, and a photo-only message without an empty bubble', () => {
    const photos = [{ id: 'p1', mediaType: 'image/jpeg', bytes: 10 }]
    const withText: ConversationMessage = { id: 'u1', role: 'user', text: 'What is this?', createdAt: '2026-01-01T00:00:00Z', status: 'complete', missionIDs: [], teamIDs: [], activity: [], photos }
    const photoOnly: ConversationMessage = { ...withText, id: 'u2', text: '' }
    const chat = { ...conversation(withText), messages: [withText, photoOnly] }
    const { container } = renderUI(<ConversationMessages conversation={chat} busy={false} handlers={{ onUpdated: vi.fn(), onRetry: vi.fn(), onEdit: vi.fn(), onQuickReply: vi.fn(), onOpenCanvas: vi.fn(), onStarter: vi.fn() }} actions={[]} onActions={vi.fn()} />)
    const images = screen.getAllByAltText('Attached photo') as HTMLImageElement[]
    expect(images).toHaveLength(2)
    expect(images[0]?.getAttribute('src')).toBe('/api/conversations/chat-1/photos/p1')
    expect(screen.getByText('What is this?')).toBeTruthy()
    expect(container.querySelectorAll('.co-user-message > p')).toHaveLength(1)
  })
})
