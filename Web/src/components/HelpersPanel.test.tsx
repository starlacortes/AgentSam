import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { api } from '../api/client'
import { I18nProvider } from '../i18n'
import { HelpersPanel } from './HelpersPanel'

vi.mock('../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../api/client')>(), api: vi.fn() }))

afterEach(() => { cleanup(); vi.mocked(api).mockReset() })

describe('HelpersPanel', () => {
  it('lists saved helper roles with their version', async () => {
    vi.mocked(api).mockResolvedValue([
      { id: 'research', function: 'research', name: 'researchAda', role: 'Cite a primary source.', groups: ['read'], version: 2, reason: 'Reports lacked sources', updatedAt: '2026-11-23T00:00:00Z' },
    ])
    render(<I18nProvider><HelpersPanel /></I18nProvider>)
    await waitFor(() => expect(screen.getByText('researchAda')).toBeTruthy())
    expect(api).toHaveBeenCalledWith('helpers')
    expect(screen.getByText(/Version 2/)).toBeTruthy()
    expect(screen.getByText('Cite a primary source.')).toBeTruthy()
  })

  it('explains the empty state', async () => {
    vi.mocked(api).mockResolvedValue([])
    render(<I18nProvider><HelpersPanel /></I18nProvider>)
    await waitFor(() => expect(screen.getByText('No saved helper roles yet. Helpers use their ready roles.')).toBeTruthy())
  })
})
