import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import type { ConversationSummary } from '../../api/types'
import { api } from '../../api/client'
import { I18nProvider } from '../../i18n'
import { ArchivedChats, daysUntilPurge, RetentionPrompt } from './ArchiveModals'
import { CoordinatorSidebar } from './CoordinatorSidebar'

vi.mock('../../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../../api/client')>(), api: vi.fn() }))
vi.mock('../../auth/AuthContext', () => ({ useAuth: () => ({ me: { name: 'Owner' }, isAdmin: false, signOut: vi.fn() }) }))

const chats: ConversationSummary[] = [
  { id: 'c1', title: 'Launch plan', projectName: 'Personal', updatedAt: '2026-11-18T00:00:00Z', running: false },
  { id: 'c2', title: 'Taxes', projectName: 'Personal', updatedAt: '2026-11-17T00:00:00Z', running: false },
]

function sidebar(overrides: Partial<Parameters<typeof CoordinatorSidebar>[0]> = {}) {
  const props = { conversations: chats, teams: [], selectedID: 'c1', open: true, onClose: vi.fn(), onSelect: vi.fn(), onNew: vi.fn(), onPanel: vi.fn(), memoryEnabled: true, onArchive: vi.fn(), onShowArchived: vi.fn(), ...overrides }
  render(<I18nProvider><MemoryRouter><CoordinatorSidebar {...props} /></MemoryRouter></I18nProvider>)
  return props
}

describe('chat archiving', () => {
  afterEach(() => { cleanup(); vi.clearAllMocks() })

  it('archives a chat from its × without opening it', () => {
    const props = sidebar()
    fireEvent.click(screen.getByRole('button', { name: 'Archive Taxes' }))
    expect(props.onArchive).toHaveBeenCalledWith('c2')
    expect(props.onSelect).not.toHaveBeenCalled()
  })

  it('reveals the archive button with a left swipe on touch screens', () => {
    sidebar()
    const row = screen.getByRole('button', { name: 'Taxes' }).parentElement!
    fireEvent.touchStart(row, { touches: [{ clientX: 200, clientY: 10 }] })
    fireEvent.touchMove(row, { touches: [{ clientX: 140, clientY: 14 }] })
    expect(row.className).toContain('revealed')
  })

  it('offers undo after archiving and links to archived chats', () => {
    const onUndoArchive = vi.fn()
    const props = sidebar({ archivedNotice: { id: 'c3', title: 'Old' }, onUndoArchive })
    fireEvent.click(screen.getByRole('button', { name: 'Undo' }))
    expect(onUndoArchive).toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Archived chats' }))
    expect(props.onShowArchived).toHaveBeenCalled()
  })

  it('asks how long to keep archives, including never delete', async () => {
    vi.mocked(api).mockResolvedValue({ retentionDays: null, configured: true })
    const onChosen = vi.fn()
    render(<I18nProvider><RetentionPrompt onChosen={onChosen} onClose={vi.fn()} /></I18nProvider>)
    fireEvent.click(screen.getByRole('radio', { name: 'Never delete' }))
    fireEvent.click(screen.getByRole('button', { name: 'Archive chat' }))
    await waitFor(() => expect(onChosen).toHaveBeenCalled())
    expect(api).toHaveBeenCalledWith('workspace/archive', { method: 'PUT', body: { retentionDays: null } })
  })

  it('lists archived chats with their deletion date and restores one', async () => {
    const archivedAt = new Date(Date.now() - 2 * 86_400_000).toISOString()
    vi.mocked(api).mockImplementation(async (path: string) => path.startsWith('conversations?')
      ? [{ ...chats[1], archivedAt }]
      : { ...chats[1], archivedAt: null })
    const onRestored = vi.fn()
    render(<I18nProvider><ArchivedChats settings={{ retentionDays: 30, configured: true }} onSettings={vi.fn()} onOpen={vi.fn()} onRestored={onRestored} onClose={vi.fn()} /></I18nProvider>)
    expect(await screen.findByText(/Deleted in 28 days/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: /Restore/ }))
    await waitFor(() => expect(onRestored).toHaveBeenCalled())
    expect(api).toHaveBeenCalledWith('conversations/c2/archive', { method: 'DELETE' })
    expect(screen.queryByText('Taxes')).toBeNull()
  })

  it('counts days until an archive is purged', () => {
    const now = Date.parse('2026-11-19T00:00:00Z')
    expect(daysUntilPurge('2026-11-10T00:00:00Z', 30, now)).toBe(21)
    expect(daysUntilPurge('2026-10-01T00:00:00Z', 30, now)).toBe(0)
    expect(daysUntilPurge('2026-11-10T00:00:00Z', null, now)).toBeNull()
  })
})
