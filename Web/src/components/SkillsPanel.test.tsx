import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { api } from '../api/client'
import { I18nProvider } from '../i18n'
import { SkillsPanel } from './SkillsPanel'

const auth = vi.hoisted(() => ({ isAdmin: true }))
vi.mock('../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../api/client')>(), api: vi.fn() }))
vi.mock('../auth/AuthContext', () => ({ useAuth: () => ({ me: { name: 'Owner' }, isAdmin: auth.isAdmin, signOut: vi.fn() }) }))

afterEach(() => { cleanup(); vi.mocked(api).mockReset(); auth.isAdmin = true })

const own = { id: 'invoice-check', name: 'Invoice check', whenToUse: 'Checking invoices.', procedure: ['Match each line'], origin: 'ada', enabled: true, updatedAt: '2026-11-24T00:00:00Z', general: false, sharedCopy: false }
const general = { ...own, id: 'old-report', name: 'Old report', general: true }
const builtIn = { ...own, id: 'research', name: 'Research', origin: 'builtIn', general: true }

describe('SkillsPanel', () => {
  it('labels private and shared skills and hides built-ins', async () => {
    auth.isAdmin = false
    vi.mocked(api).mockResolvedValue([builtIn, own, general])
    render(<I18nProvider><SkillsPanel /></I18nProvider>)
    await waitFor(() => expect(screen.getByText('Invoice check')).toBeTruthy())
    expect(screen.queryByText('Research')).toBeNull()
    expect(screen.getByText(/Only you/)).toBeTruthy()
    expect(screen.getByText(/Shared with everyone/)).toBeTruthy()
    expect(screen.queryByText('Share with everyone…')).toBeNull()
    expect(screen.queryByText('Stop sharing')).toBeNull()
  })

  it('lets an admin share only after ticking every check', async () => {
    vi.mocked(api).mockResolvedValueOnce([own])
    render(<I18nProvider><SkillsPanel /></I18nProvider>)
    await waitFor(() => expect(screen.getByText('Share with everyone…')).toBeTruthy())
    fireEvent.click(screen.getByText('Share with everyone…'))
    const button = screen.getByText('Share with everyone') as HTMLButtonElement
    expect(button.disabled).toBe(true)
    for (const box of screen.getAllByRole('checkbox')) fireEvent.click(box)
    expect(button.disabled).toBe(false)
    vi.mocked(api).mockResolvedValueOnce([{ ...own, sharedCopy: true }])
    fireEvent.click(button)
    await waitFor(() => expect(api).toHaveBeenCalledWith('skills/invoice-check/share', { method: 'POST', body: { general: true } }))
    await waitFor(() => expect(screen.getByText(/Yours, also shared/)).toBeTruthy())
  })
})
