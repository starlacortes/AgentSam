import type { ChoiceCard } from '../../api/types'

// Sample choice cards for tests and screenshots, shaped like what the server saves.

export function singleChoice(): ChoiceCard {
  return {
    id: 'c-single', title: 'Cleaning day', state: 'pending',
    questions: [{ id: 'day', question: 'Which day works best for the deep clean?', multiple: false, other: false, options: [
      { label: 'Monday', detail: 'Crew of three, done by 2 pm' },
      { label: 'Wednesday', detail: 'Crew of two, all day' },
      { label: 'Saturday', detail: 'Weekend rate, +15%' },
    ] }],
  }
}

export function multiChoice(): ChoiceCard {
  return {
    id: 'c-multi', state: 'pending',
    questions: [{ id: 'rooms', question: 'Which rooms should the crew cover?', multiple: true, other: true, options: [
      { label: 'Kitchen' }, { label: 'Bathrooms' }, { label: 'Bedrooms' }, { label: 'Living room' }, { label: 'Windows', detail: 'Inside only' },
    ] }],
  }
}

export function flowChoice(): ChoiceCard {
  return {
    id: 'c-flow', title: 'Social media plan', state: 'pending',
    questions: [
      { id: 'goal', question: 'What do you want social media to do first?', multiple: false, other: false, options: [
        { label: 'Get new clients', detail: 'Local reach and booking links' },
        { label: 'Keep current clients', detail: 'Reminders, offers, tips' },
        { label: 'Hire cleaners', detail: 'Job posts and team culture' },
      ] },
      { id: 'area', question: 'Which area should new clients come from?', multiple: false, other: true, showIf: { question: 'goal', anyOf: ['Get new clients'] }, options: [
        { label: 'Within 5 miles' }, { label: 'The whole city' },
      ] },
      { id: 'where', question: 'Where should Ada post?', multiple: true, other: false, options: [
        { label: 'Instagram' }, { label: 'Facebook' }, { label: 'Google Business' }, { label: 'Nextdoor' },
      ] },
    ],
  }
}
