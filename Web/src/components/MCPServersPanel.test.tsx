import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { api } from '../api/client'
import type { MCPServerView } from '../api/types'
import { I18nProvider } from '../i18n'
import { MCPServersPanel } from './MCPServersPanel'

vi.mock('../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../api/client')>(), api: vi.fn() }))

const server: MCPServerView = {
  id: 's1', name: 'Notes', slug: 'notes', url: 'https://notes.example.test/mcp', enabled: true, hasToken: true,
  tools: [
    { name: 'search', exposedName: 'mcp_notes_search', description: 'Search notes.', readOnlyHint: true, read: true },
    { name: 'create', exposedName: 'mcp_notes_create', description: 'Create a note.', readOnlyHint: false, read: false },
  ],
}

afterEach(() => { cleanup(); vi.mocked(api).mockReset() })

describe('MCPServersPanel', () => {
  it('adds a server and marks a tool read-only', async () => {
    vi.mocked(api).mockImplementation(async (path: string, init?: { method?: string; body?: unknown }) => {
      if (path === 'mcp/servers' && !init) return [] as never
      if (path === 'mcp/servers' && init?.method === 'POST') return server as never
      if (init?.method === 'PUT') return { ...server, tools: server.tools.map((tool) => ({ ...tool, read: true })) } as never
      throw new Error(`unexpected ${path}`)
    })
    render(<I18nProvider><MCPServersPanel /></I18nProvider>)
    expect(await screen.findByText('No MCP servers yet.')).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Server URL'), { target: { value: 'https://notes.example.test/mcp' } })
    fireEvent.change(screen.getByLabelText('Bearer token (optional)'), { target: { value: 'tok' } })
    fireEvent.click(screen.getByRole('button', { name: /Connect/ }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('mcp/servers', { method: 'POST', body: { name: '', url: 'https://notes.example.test/mcp', token: 'tok' } }))
    const create = await screen.findByText('create')
    fireEvent.click(create.closest('label')!.querySelector('input')!)
    await waitFor(() => expect(api).toHaveBeenCalledWith('mcp/servers/s1', { method: 'PUT', body: { readTools: ['search', 'create'] } }))
  })
})
