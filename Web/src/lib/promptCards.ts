import { api } from '../api/client'

/** A prompt the person saved to reuse. Tapping its card puts the text in the composer. */
export interface PromptCard {
  id: string
  title: string
  text: string
  createdAt: string
}

/** The most cards the empty chat shows; the rest are a tap away in the prompt cards list. */
export const EMPTY_CHAT_CARDS = 6

export const listPromptCards = () => api<PromptCard[]>('prompt-cards')

export const savePromptCard = (card: { id?: string; title: string; text: string }) =>
  card.id
    ? api<PromptCard>(`prompt-cards/${card.id}`, { method: 'PUT', body: { title: card.title, text: card.text } })
    : api<PromptCard>('prompt-cards', { method: 'POST', body: { title: card.title, text: card.text } })

export const deletePromptCard = (id: string) => api<string>(`prompt-cards/${id}`, { method: 'DELETE' })

/** Puts a saved or edited card in place, keeping the list in the order the cards were made. */
export function upsertCard(cards: PromptCard[], card: PromptCard): PromptCard[] {
  return cards.some((item) => item.id === card.id) ? cards.map((item) => item.id === card.id ? card : item) : [...cards, card]
}
