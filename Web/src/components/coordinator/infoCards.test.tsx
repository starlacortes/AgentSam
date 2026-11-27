import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { I18nProvider } from '../../i18n'
import type { Conversation, InfoCard } from '../../api/types'
import { ConversationMessages } from './ConversationMessages'
import { InfoCardView, niceTicks, withUnit } from './InfoCards'
import { sampleCards } from './cardFixtures.test-data'

const handlers = () => ({ onUpdated: vi.fn(), onRetry: vi.fn(), onEdit: vi.fn(), onQuickReply: vi.fn(), onOpenCanvas: vi.fn(), onStarter: vi.fn() })
const view = (card: InfoCard) => render(<I18nProvider><InfoCardView card={card} /></I18nProvider>)
const find = (template: string) => sampleCards().find((card) => card.template === template)!

describe('Ada cards', () => {
  afterEach(() => { cleanup() })

  it('draws every template', () => {
    for (const card of sampleCards()) {
      const { container } = view(card)
      expect(container.querySelector(`.co-card.${card.template}-card`), card.template).toBeTruthy()
      cleanup()
    }
  })

  it('shows stats with their change', () => {
    view(find('stats'))
    expect(screen.getByText('$1,284')).toBeTruthy()
    expect(screen.getByText(/\+21% vs Oct/).className).toContain('good')
  })

  it('marks the recommended column in a comparison', () => {
    const { container } = view(find('comparison'))
    expect(screen.getByText('Recommended')).toBeTruthy()
    expect(container.querySelectorAll('td.best')).toHaveLength(4)
  })

  it('reads out a chart point on focus and keeps a table for screen readers', () => {
    const { container } = view(find('chart'))
    expect(container.querySelectorAll('.co-card-bar')).toHaveLength(7)
    fireEvent.focus(screen.getByLabelText('Tue: 18 bookings'))
    expect(container.querySelector('.co-card-readout')?.textContent).toBe('Tue18 bookings')
    expect(container.querySelectorAll('table.co-card-sr tr')).toHaveLength(7)
  })

  it('never renders text from a card as markup', () => {
    const { container } = view({ id: 'x', template: 'summary', items: [{ label: '<img src=x onerror=alert(1)>', value: '<b>bold</b>' }], columns: [], rows: [] })
    expect(container.querySelector('img')).toBeNull()
    expect(container.querySelector('b')).toBeNull()
    expect(screen.getByText('<b>bold</b>')).toBeTruthy()
  })

  it('skips a template it does not know', () => {
    const { container } = view({ id: 'x', template: 'map', items: [{ label: 'x' }], columns: [], rows: [] })
    expect(container.innerHTML).toBe('')
  })

  it('shows cards under the reply and after a reload', () => {
    const conversation: Conversation = {
      id: 'c', title: 'Ads', createdAt: '2026-11-27T10:00:00Z', updatedAt: '2026-11-27T10:00:00Z',
      messages: [
        { id: 'u', role: 'user', text: 'How are the ads doing?', createdAt: '2026-11-27T10:00:00Z', status: 'complete', missionIDs: [], teamIDs: [], activity: [] },
        { id: 'a', role: 'assistant', text: 'Leads are up a fifth on October at a lower cost each.', createdAt: '2026-11-27T10:00:05Z', status: 'complete', missionIDs: [], teamIDs: [], activity: [], cards: [find('stats')] },
      ],
    } as unknown as Conversation
    const { container } = render(<MemoryRouter><I18nProvider><ConversationMessages conversation={conversation} handlers={handlers()} /></I18nProvider></MemoryRouter>)
    const reply = container.querySelector('.co-ada-message')!
    expect(reply.querySelector('.co-cards .stats-card')).toBeTruthy()
    // The card comes after the text, which still answers on its own.
    expect(reply.querySelector('.co-response')!.compareDocumentPosition(reply.querySelector('.co-cards')!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('formats units and axis steps', () => {
    expect(withUnit('12', '$')).toBe('$12')
    expect(withUnit('40', '%')).toBe('40%')
    expect(withUnit('5', 'visits')).toBe('5 visits')
    expect(niceTicks(0, 30)).toEqual([0, 10, 20, 30])
    expect(niceTicks(3200, 4630)[0]).toBeLessThanOrEqual(3200)
  })
})
