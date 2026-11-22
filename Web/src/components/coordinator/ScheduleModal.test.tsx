import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { api } from '../../api/client'
import type { Conversation } from '../../api/types'
import { I18nProvider } from '../../i18n'
import { ScheduleModal } from './ScheduleModal'

vi.mock('../../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../../api/client')>(), api: vi.fn() }))

const base: Conversation = {
  id: 'c1', title: 'Chat', projectName: 'Personal', updatedAt: '2026-11-22T00:00:00Z', running: false,
  ownerID: 'owner', createdAt: '2026-11-22T00:00:00Z', messages: [],
}

afterEach(() => { cleanup(); vi.mocked(api).mockReset() })

describe('ScheduleModal', () => {
  it('schedules a prompt for weekdays at a set time', async () => {
    vi.mocked(api).mockResolvedValue(base as never)
    const onUpdated = vi.fn()
    render(<I18nProvider><ScheduleModal conversation={base} onUpdated={onUpdated} onClose={() => {}} /></I18nProvider>)
    fireEvent.change(screen.getAllByLabelText('Prompt to run')[0]!, { target: { value: 'Morning digest' } })
    fireEvent.click(screen.getByRole('button', { name: 'At a set time' }))
    fireEvent.change(screen.getByLabelText('Time'), { target: { value: '07:30' } })
    fireEvent.click(screen.getByRole('button', { name: 'Schedule it' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('conversations/c1/schedule', {
      method: 'PUT',
      body: expect.objectContaining({ prompt: 'Morning digest', at: '07:30', days: 'mon,tue,wed,thu,fri' }),
    }))
    expect(onUpdated).toHaveBeenCalled()
  })

  it('lists a webhook trigger with its address, resumes a paused one and adds a new one', async () => {
    const conversation: Conversation = {
      ...base,
      triggers: [
        { id: 't1', kind: 'webhook', prompt: 'Tell me how the deploy went', language: 'en', token: 'a'.repeat(64), createdAt: base.createdAt },
        { id: 't2', kind: 'gmail', prompt: 'File it', language: 'en', query: 'from:billing@example.com', createdAt: base.createdAt, pausedAt: base.createdAt, failures: 3 },
      ],
    }
    vi.mocked(api).mockResolvedValue(conversation as never)
    render(<I18nProvider><ScheduleModal conversation={conversation} gmailConnected onUpdated={() => {}} onClose={() => {}} /></I18nProvider>)
    expect(screen.getByText(`${window.location.origin}/api/hooks/${'a'.repeat(64)}`)).toBeTruthy()
    expect(screen.getByText('Paused after 3 failed runs in a row.')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Resume' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('conversations/c1/triggers/t2/resume', { method: 'POST' }))
    fireEvent.change(screen.getByLabelText('Gmail search'), { target: { value: 'from:boss@example.com' } })
    fireEvent.change(screen.getAllByLabelText('Prompt to run')[1]!, { target: { value: 'Summarize it' } })
    fireEvent.click(screen.getByRole('button', { name: 'Add trigger' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('conversations/c1/triggers', {
      method: 'POST',
      body: { kind: 'gmail', prompt: 'Summarize it', query: 'from:boss@example.com', language: 'en' },
    }))
  })
})
