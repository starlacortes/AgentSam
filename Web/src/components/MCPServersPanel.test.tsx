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
      if (path === 'mcp/catalog') return [] as never
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

  it('adds every suggested free server with one click and names the ones that fail', async () => {
    const posted: unknown[] = []
    vi.mocked(api).mockImplementation(async (path: string, init?: { method?: string; body?: unknown }) => {
      if (path === 'mcp/servers' && !init) return [] as never
      if (path === 'mcp/catalog') return [
        { id: 'deepwiki', name: 'DeepWiki', url: 'https://mcp.deepwiki.com/mcp', detail: 'Repos.', added: false },
        { id: 'down', name: 'Down', url: 'https://down.example/mcp', detail: 'Offline.', added: false },
        { id: 'have', name: 'Have', url: 'https://have.example/mcp', detail: 'Already here.', added: true },
      ] as never
      if (path === 'mcp/servers' && init?.method === 'POST') {
        posted.push(init.body)
        if ((init.body as { name: string }).name === 'Down') throw new Error('unreachable')
        return { ...server, id: 'd1', name: 'DeepWiki' } as never
      }
      throw new Error(`unexpected ${path}`)
    })
    render(<I18nProvider><MCPServersPanel /></I18nProvider>)
    expect(screen.queryByText('Have')).toBeNull()
    fireEvent.click(await screen.findByRole('button', { name: /Add all/ }))
    expect(await screen.findByText('These did not answer and were skipped: Down')).toBeTruthy()
    expect(posted).toEqual([{ name: 'DeepWiki', url: 'https://mcp.deepwiki.com/mcp' }, { name: 'Down', url: 'https://down.example/mcp' }])
  })
})
