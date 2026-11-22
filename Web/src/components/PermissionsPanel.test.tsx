import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { api } from '../api/client'
import type { PermissionsView } from '../api/types'
import { I18nProvider } from '../i18n'
import { PermissionsPanel } from './PermissionsPanel'

vi.mock('../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../api/client')>(), api: vi.fn() }))

const view = (canEdit: boolean): PermissionsView => ({
  policy: { paused: false, rules: {}, approvalMinutes: 15 },
  usageToday: {},
  tools: ['gmail_draft', 'googleads_set_budget'],
  canEdit,
})

afterEach(() => { cleanup(); vi.mocked(api).mockReset() })

describe('PermissionsPanel', () => {
  it('saves an allow rule with its budget limit', async () => {
    vi.mocked(api).mockImplementation(async (_path: string, init?: { method?: string; body?: unknown }) => {
      if (init?.method === 'PUT') return { ...view(true), policy: init.body } as never
      return view(true) as never
    })
    render(<I18nProvider><PermissionsPanel /></I18nProvider>)
    const budget = await screen.findByLabelText('Change Google Ads budgets')
    fireEvent.change(budget, { target: { value: 'allow' } })
    fireEvent.change(screen.getByLabelText('Largest daily budget'), { target: { value: '20' } })
    fireEvent.click(screen.getByRole('button', { name: /Save permissions/ }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('access/permissions', {
      method: 'PUT',
      body: { paused: false, approvalMinutes: 15, rules: { googleads_set_budget: { mode: 'allow', maxAmount: 20 } } },
    }))
    expect(await screen.findByText('Saved.')).toBeTruthy()
  })

  it('is read-only for members', async () => {
    vi.mocked(api).mockResolvedValue(view(false) as never)
    render(<I18nProvider><PermissionsPanel /></I18nProvider>)
    const draft = await screen.findByLabelText('Create Gmail drafts')
    expect((draft as HTMLSelectElement).disabled).toBe(true)
    expect(screen.queryByRole('button', { name: /Save permissions/ })).toBeNull()
  })
})
