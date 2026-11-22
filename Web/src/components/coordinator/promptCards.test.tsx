import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { I18nProvider } from '../../i18n'
import { ConversationMessages } from './ConversationMessages'
import { PromptCardsModal } from './PromptCardsModal'
import type { PromptCard } from '../../lib/promptCards'

const card = (id: string, title: string, text: string): PromptCard => ({ id, title, text, createdAt: '2026-11-22T00:00:00Z' })
const handlers = () => ({ onUpdated: vi.fn(), onRetry: vi.fn(), onEdit: vi.fn(), onQuickReply: vi.fn(), onOpenCanvas: vi.fn(), onStarter: vi.fn(), onPromptCards: vi.fn() })

describe('prompt cards', () => {
  afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.restoreAllMocks() })

  it('shows saved cards on the empty chat in place of the starters', () => {
    const actions = handlers()
    render(<MemoryRouter><I18nProvider><ConversationMessages conversation={null} handlers={actions} promptCards={[card('1', 'Weekly report', 'Summarize this week')]} /></I18nProvider></MemoryRouter>)
    expect(screen.queryByText('Build a web page')).toBeNull()
    fireEvent.click(screen.getByText('Weekly report'))
    expect(actions.onStarter).toHaveBeenCalledWith('Summarize this week')
    fireEvent.click(screen.getByRole('button', { name: 'Edit prompt cards' }))
    expect(actions.onPromptCards).toHaveBeenCalled()
  })

  it('keeps the built-in starters until a card is saved', () => {
    const actions = handlers()
    render(<MemoryRouter><I18nProvider><ConversationMessages conversation={null} handlers={actions} /></I18nProvider></MemoryRouter>)
    expect(screen.getByText('Build a web page')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Save your own prompt cards' }))
    expect(actions.onPromptCards).toHaveBeenCalled()
  })

  it('saves a new card, uses one, and deletes one', async () => {
    const saved = card('2', 'Client reply', 'Draft a reply')
    const fetch = vi.fn(async (url: string, init?: RequestInit) => {
      if (init?.method === 'POST') {
        expect(JSON.parse(String(init.body))).toEqual({ title: 'Client reply', text: 'Draft a reply' })
        return new Response(JSON.stringify(saved), { status: 201, headers: { 'content-type': 'application/json' } })
      }
      if (init?.method === 'DELETE') { expect(url).toBe('/api/prompt-cards/1'); return new Response(null, { status: 204 }) }
      throw new Error(`unexpected ${url}`)
    })
    vi.stubGlobal('fetch', fetch)
    const onChange = vi.fn()
    const onUse = vi.fn()
    const existing = card('1', 'Weekly report', 'Summarize this week')
    render(<I18nProvider><PromptCardsModal cards={[existing]} draft="Draft a reply" onChange={onChange} onUse={onUse} onClose={vi.fn()} /></I18nProvider>)
    expect((screen.getByRole('textbox', { name: 'Prompt' }) as HTMLTextAreaElement).value).toBe('Draft a reply')
    fireEvent.change(screen.getByRole('textbox', { name: 'Title (optional)' }), { target: { value: 'Client reply' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save card' }))
    await waitFor(() => expect(onChange).toHaveBeenCalledWith([existing, saved]))
    fireEvent.click(screen.getByRole('button', { name: 'Use prompt card Weekly report' }))
    expect(onUse).toHaveBeenCalledWith('Summarize this week')
    fireEvent.click(screen.getByRole('button', { name: 'Delete prompt card' }))
    await waitFor(() => expect(onChange).toHaveBeenLastCalledWith([]))
  })
})
