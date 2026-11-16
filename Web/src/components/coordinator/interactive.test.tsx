import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import type { Conversation, ConversationMessage, RunEvent } from '../../api/types'
import { I18nProvider } from '../../i18n'
import { attachmentBlock } from '../../pages/CoordinatorPage'
import { ConversationMessages, type MessageHandlers } from './ConversationMessages'
import { consoleRows } from './SidePanel'
import { formatElapsed, ThinkingIndicator } from './ThinkingIndicator'

vi.mock('../../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../../api/client')>(), api: vi.fn().mockResolvedValue({ deliverables: [] }) }))
vi.mock('../../auth/AuthContext', () => ({ useAuth: () => ({ me: { name: 'Owner' }, isAdmin: false, signOut: vi.fn() }) }))

function assistant(overrides: Partial<ConversationMessage> = {}): ConversationMessage {
  return { id: 'a1', role: 'assistant', text: 'Done.', createdAt: new Date(Date.now() - 5000).toISOString(), status: 'complete', missionIDs: [], teamIDs: [], activity: [], ...overrides }
}

function chat(messages: ConversationMessage[]): Conversation {
  return { id: 'chat-1', ownerID: 'owner', title: 'T', projectName: 'Personal', createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z', running: false, messages } as Conversation
}

function handlers(): MessageHandlers {
  return { onUpdated: vi.fn(), onRevise: vi.fn(), onRetry: vi.fn(), onEdit: vi.fn(), onQuickReply: vi.fn(), onOpenCanvas: vi.fn(), onStarter: vi.fn() }
}

function renderUI(ui: React.ReactNode) {
  return render(<I18nProvider><MemoryRouter>{ui}</MemoryRouter></I18nProvider>)
}

describe('interactive chat', () => {
  afterEach(() => { cleanup(); vi.clearAllMocks() })

  it('sends a quick reply with one click, only on the latest answer', () => {
    const h = handlers()
    const user: ConversationMessage = { ...assistant({ id: 'u1', role: 'user', text: 'Pitch?' }) }
    renderUI(<ConversationMessages conversation={chat([assistant({ id: 'old', quickReplies: ['Old option'] }), user, assistant({ quickReplies: ['Customers', 'Investors'] })])} handlers={h} />)
    expect(screen.queryByRole('button', { name: 'Old option' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Investors' }))
    expect(h.onQuickReply).toHaveBeenCalledWith('Investors')
  })

  it('labels a scheduled run instead of showing it as plain user text', () => {
    const h = handlers()
    const scheduled: ConversationMessage = { ...assistant({ id: 's1', role: 'user', text: 'Refresh the list', scheduled: true }) }
    const plain: ConversationMessage = { ...assistant({ id: 'u1', role: 'user', text: 'Hello' }) }
    const { unmount } = renderUI(<ConversationMessages conversation={chat([scheduled, plain, assistant({ text: 'Refreshed with 3 new messages.' })])} handlers={h} />)
    expect(screen.getByText('Scheduled run')).toBeTruthy()
    expect(screen.getByText('Refresh the list')).toBeTruthy()
    expect(screen.getAllByText('Hello').length).toBe(1)
    unmount()
    renderUI(<ConversationMessages conversation={chat([plain])} handlers={h} />)
    expect(screen.queryByText('Scheduled run')).toBeNull()
  })

  it('lists files Ada wrote as chips that open the workspace preview', () => {
    const h = handlers()
    renderUI(<ConversationMessages conversation={chat([
      assistant({ text: 'I made you a page.', fileIDs: ['index.html', 'notes.md'] }),
    ])} handlers={h} />)
    const pageChip = screen.getByRole('button', { name: /index\.html/ })
    fireEvent.click(pageChip)
    expect(h.onOpenCanvas).toHaveBeenCalledWith(expect.objectContaining({ tab: 'preview', source: { kind: 'chat', conversationID: 'chat-1', entry: 'index.html' } }))
    fireEvent.click(screen.getByRole('button', { name: /notes\.md/ }))
    expect(h.onOpenCanvas).toHaveBeenCalledWith(expect.objectContaining({ tab: 'files', source: { kind: 'chat', conversationID: 'chat-1', entry: undefined } }))
  })

  it('opens shared project files from the project workspace', () => {
    const h = handlers()
    renderUI(<ConversationMessages conversation={chat([
      assistant({ fileIDs: ['project:index.html', 'project:notes.md'] }),
    ])} handlers={h} />)
    fireEvent.click(screen.getByRole('button', { name: 'project:index.html' }))
    expect(h.onOpenCanvas).toHaveBeenCalledWith(expect.objectContaining({ tab: 'preview', source: { kind: 'project', conversationID: 'chat-1', entry: 'index.html' } }))
    fireEvent.click(screen.getByRole('button', { name: 'project:notes.md' }))
    expect(h.onOpenCanvas).toHaveBeenCalledWith(expect.objectContaining({ tab: 'files', source: { kind: 'project', conversationID: 'chat-1', entry: undefined } }))
  })

  it('opens an HTML code block in the preview panel', () => {
    const h = handlers()
    renderUI(<ConversationMessages conversation={chat([assistant({ text: '```html\n<h1>Hi</h1>\n```' })])} handlers={h} />)
    fireEvent.click(screen.getByRole('button', { name: 'Preview' }))
    expect(h.onOpenCanvas).toHaveBeenCalledWith(expect.objectContaining({ tab: 'preview', source: expect.objectContaining({ kind: 'code', language: 'html', code: '<h1>Hi</h1>\n' }) }))
  })

  it('lets the user edit and resend their message', () => {
    const h = handlers()
    renderUI(<ConversationMessages conversation={chat([assistant({ id: 'u1', role: 'user', text: 'Make it blue' })])} handlers={h} />)
    fireEvent.click(screen.getByRole('button', { name: 'Edit and resend' }))
    expect(h.onEdit).toHaveBeenCalledWith('Make it blue')
  })

  it('shows the current step, elapsed time, and the step list while working', () => {
    const now = Date.now()
    const message = assistant({ status: 'running', text: '', createdAt: new Date(now - 12000).toISOString(), steps: [
      { id: 's1', label: 'Choosing how to help', state: 'done', startedAt: new Date(now - 12000).toISOString(), finishedAt: new Date(now - 9000).toISOString() },
      { id: 's2', label: 'Searching Gmail', state: 'working', startedAt: new Date(now - 9000).toISOString() },
    ] })
    renderUI(<ThinkingIndicator message={message} />)
    expect(screen.getByText('Searching Gmail…')).toBeTruthy()
    expect(screen.getByText('12s')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: /2 steps/ }))
    expect(screen.getByText('Choosing how to help')).toBeTruthy()
  })

  it('formats elapsed time', () => {
    expect(formatElapsed(800)).toBe('1s')
    expect(formatElapsed(65_000)).toBe('1m 05s')
  })

  it('merges agent work and page console output in time order', () => {
    const events: RunEvent[] = [
      { id: 'e1', seq: 1, missionID: 'm', timestamp: new Date(1000).toISOString(), kind: 'toolCall', agentName: 'Scout', text: 'write_file index.html' },
      { id: 'e2', seq: 2, missionID: 'm', timestamp: new Date(3000).toISOString(), kind: 'error', agentName: 'Scout', text: 'boom' },
      { id: 'e3', seq: 3, missionID: 'm', timestamp: new Date(3500).toISOString(), kind: 'cost', costUSD: 0.01 },
    ]
    const rows = consoleRows(events, [{ level: 'warn', text: 'deprecated', time: 2000 }])
    expect(rows.map((row) => row.text)).toEqual(['write_file index.html', 'deprecated', 'boom'])
    expect(rows.map((row) => row.level)).toEqual(['info', 'warn', 'error'])
  })

  it('wraps attachments in a fence that survives backticks inside', () => {
    expect(attachmentBlock('notes.md', 'hi\n')).toBe('notes.md:\n```md\nhi\n```\n')
    expect(attachmentBlock('a.md', '```js\nx\n```')).toContain('~~~~md')
  })
})
