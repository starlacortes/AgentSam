import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { I18nProvider } from '../../i18n'
import type { ChoiceCard, Conversation } from '../../api/types'
import { ConversationMessages } from './ConversationMessages'
import { answerSummary, buildReply, ChoiceCardView, visibleQuestions } from './ChoiceCard'
import { flowChoice, multiChoice, singleChoice } from './choiceFixtures.test-data'

const view = (card: ChoiceCard, onAnswer = vi.fn(), active = true) => ({ onAnswer, ...render(<I18nProvider><ChoiceCardView card={card} active={active} onAnswer={onAnswer} /></I18nProvider>) })

describe('Ada choice cards', () => {
  afterEach(() => { cleanup(); vi.useRealTimers() })

  it('shows a branch only after one of its answers', () => {
    const card = flowChoice()
    expect(visibleQuestions(card, {}).map((q) => q.id)).toEqual(['goal', 'where'])
    expect(visibleQuestions(card, { goal: { picked: [1], other: '', otherOn: false } }).map((q) => q.id)).toEqual(['goal', 'where'])
    expect(visibleQuestions(card, { goal: { picked: [0], other: '', otherOn: false } }).map((q) => q.id)).toEqual(['goal', 'area', 'where'])
    // Answers to a hidden question are not sent; their own words replace a one-pick option.
    expect(buildReply(card, { goal: { picked: [1], other: '', otherOn: false }, area: { picked: [0], other: '', otherOn: false }, where: { picked: [0, 2], other: '', otherOn: false } }).answers)
      .toEqual([{ question: 'goal', picked: [1] }, { question: 'where', picked: [0, 2] }])
    expect(buildReply(card, { goal: { picked: [0], other: '', otherOn: false }, area: { picked: [1], other: ' Uptown ', otherOn: true } }).answers[1]).toEqual({ question: 'area', picked: [], other: 'Uptown' })
  })

  it('sends a one-question, one-pick card on the first tap', () => {
    const { onAnswer } = view(singleChoice())
    expect(screen.getByRole('radiogroup')).toBeTruthy()
    expect(screen.getByText('Crew of two, all day')).toBeTruthy()
    fireEvent.click(screen.getByRole('radio', { name: /Wednesday/ }))
    expect(onAnswer).toHaveBeenCalledWith({ cardID: 'c-single', answers: [{ question: 'day', picked: [1] }] }, 'Which day works best for the deep clean? → Wednesday')
    // Nothing more can be picked while it is sent.
    expect((screen.getByRole('radio', { name: /Monday/ }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('lets several be picked, with their own answer, and sends on Send', () => {
    const { onAnswer } = view(multiChoice())
    const send = screen.getByRole('button', { name: 'Send' }) as HTMLButtonElement
    expect(send.disabled).toBe(true)
    fireEvent.click(screen.getByRole('checkbox', { name: /Kitchen/ }))
    fireEvent.click(screen.getByRole('checkbox', { name: /Windows/ }))
    fireEvent.click(screen.getByRole('checkbox', { name: /Kitchen/ }))
    fireEvent.click(screen.getByRole('checkbox', { name: /Bathrooms/ }))
    fireEvent.click(screen.getByRole('checkbox', { name: /Something else/ }))
    fireEvent.change(screen.getByLabelText('Your own answer'), { target: { value: 'Garage' } })
    expect(screen.getByRole('checkbox', { name: /Bathrooms/ }).getAttribute('aria-checked')).toBe('true')
    fireEvent.click(send)
    expect(onAnswer).toHaveBeenCalledWith({ cardID: 'c-multi', answers: [{ question: 'rooms', picked: [1, 4], other: 'Garage' }] }, 'Which rooms should the crew cover? → Bathrooms, Windows, Garage')
  })

  it('walks a multi-step flow with Back, a branch and a review', () => {
    vi.useFakeTimers()
    const { onAnswer } = view(flowChoice())
    expect(screen.getByText('1 of 2')).toBeTruthy()
    fireEvent.click(screen.getByRole('radio', { name: /Get new clients/ }))
    act(() => { vi.advanceTimersByTime(300) })
    // The branch now shows, so there are three questions.
    expect(screen.getByText('Which area should new clients come from?')).toBeTruthy()
    expect(screen.getByText('2 of 3')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    expect(screen.getByRole('radio', { name: /Get new clients/ }).getAttribute('aria-checked')).toBe('true')
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    fireEvent.click(screen.getByRole('radio', { name: /The whole city/ }))
    act(() => { vi.advanceTimersByTime(300) })
    fireEvent.click(screen.getByRole('checkbox', { name: /Instagram/ }))
    fireEvent.click(screen.getByRole('checkbox', { name: /Nextdoor/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Review' }))
    expect(screen.getByText('Check your answers')).toBeTruthy()
    expect(screen.getByText('Instagram, Nextdoor')).toBeTruthy()
    // Change goes back to that question.
    fireEvent.click(screen.getAllByRole('button', { name: 'Change' })[1]!)
    expect(screen.getByText('Which area should new clients come from?')).toBeTruthy()
    fireEvent.click(screen.getByRole('radio', { name: /Within 5 miles/ }))
    act(() => { vi.advanceTimersByTime(300) })
    fireEvent.click(screen.getByRole('button', { name: 'Review' }))
    fireEvent.click(screen.getByRole('button', { name: /Send answers/ }))
    expect(onAnswer).toHaveBeenCalledTimes(1)
    expect(onAnswer.mock.calls[0]?.[0]).toEqual({ cardID: 'c-flow', answers: [{ question: 'goal', picked: [0] }, { question: 'area', picked: [0] }, { question: 'where', picked: [0, 3] }] })
  })

  it('folds once answered and opens to show the answers', () => {
    const card: ChoiceCard = { ...flowChoice(), state: 'answered', answer: { cardID: 'c-flow', inWords: false, items: [
      { questionID: 'goal', question: 'What do you want social media to do first?', picked: ['Get new clients'] },
      { questionID: 'where', question: 'Where should Ada post?', picked: ['Instagram', 'Facebook'] },
    ] } }
    expect(answerSummary(card.answer)).toBe('Get new clients · Instagram, Facebook')
    view(card)
    const summary = screen.getByRole('button', { expanded: false })
    expect(summary.textContent).toContain('Social media plan')
    expect(summary.textContent).toContain('Answered')
    expect(screen.queryByRole('radio')).toBeNull()
    fireEvent.click(summary)
    expect(screen.getByText('Where should Ada post?')).toBeTruthy()
  })

  it('takes no answers when it is not the latest reply', () => {
    view(singleChoice(), vi.fn(), false)
    expect(screen.queryByRole('radio')).toBeNull()
    expect(screen.getByText('No longer open')).toBeTruthy()
  })

  it('draws in the chat, hides a text that only repeats the question, and shows the answers as a card', () => {
    const card = singleChoice()
    const question = card.questions[0]!.question
    const onChoice = vi.fn()
    const base = { createdAt: '2026-11-27T10:00:00Z', status: 'complete', missionIDs: [], teamIDs: [], activity: [] } as const
    const ask = { ...base, id: 'u1', role: 'user', text: 'Book a deep clean' }
    const reply = { ...base, id: 'a1', role: 'assistant', text: question, choice: card }
    const chat = (messages: unknown[]) => ({ id: 'chat', title: 'x', createdAt: base.createdAt, updatedAt: base.createdAt, messages }) as unknown as Conversation
    const handlers = { onUpdated: vi.fn(), onRetry: vi.fn(), onEdit: vi.fn(), onQuickReply: vi.fn(), onOpenCanvas: vi.fn(), onStarter: vi.fn(), onChoice }
    const { rerender } = render(<MemoryRouter><I18nProvider><ConversationMessages conversation={chat([ask, reply])} handlers={handlers} /></I18nProvider></MemoryRouter>)
    expect(screen.getAllByText(question)).toHaveLength(1)
    fireEvent.click(screen.getByRole('radio', { name: /Saturday/ }))
    expect(onChoice).toHaveBeenCalledWith({ cardID: 'c-single', answers: [{ question: 'day', picked: [2] }] }, expect.stringContaining('Saturday'))

    const answer = { cardID: card.id, inWords: false, items: [{ questionID: 'day', question, picked: ['Saturday'] }] }
    const answered = [ask, { ...reply, choice: { ...card, state: 'answered', answer } }, { ...base, id: 'u2', role: 'user', text: 'My answers…', choiceReply: answer }]
    rerender(<MemoryRouter><I18nProvider><ConversationMessages conversation={chat(answered)} handlers={handlers} /></I18nProvider></MemoryRouter>)
    expect(screen.getByText('Your answers')).toBeTruthy()
    expect(screen.queryByText('My answers…')).toBeNull()
    expect(screen.queryByRole('radio')).toBeNull()
    expect(screen.getAllByLabelText('Edit and resend')).toHaveLength(1)
  })
})
