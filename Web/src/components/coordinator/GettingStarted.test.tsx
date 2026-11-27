import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { I18nProvider } from '../../i18n'
import { GettingStarted } from './GettingStarted'

afterEach(cleanup)

describe('getting started', () => {
  it('links the steps still to do and ticks the ones that are done', () => {
    const onDismiss = vi.fn()
    render(<MemoryRouter><I18nProvider><GettingStarted onDismiss={onDismiss} steps={[
      { id: 'key', done: true, to: '/settings/providers' },
      { id: 'service', done: false, to: '/settings/connections' },
      { id: 'alerts', done: false, to: '/settings/permissions' },
    ]} /></I18nProvider></MemoryRouter>)
    expect(screen.getByText('1 of 3 done')).toBeTruthy()
    expect(screen.queryByRole('link', { name: /Add a model key/ })).toBeNull()
    expect(screen.getByRole('link', { name: /Connect a service/ }).getAttribute('href')).toBe('/settings/connections')
    expect(screen.getByRole('link', { name: /Turn on alerts/ }).getAttribute('href')).toBe('/settings/permissions')
    fireEvent.click(screen.getByRole('button', { name: 'Hide getting started' }))
    expect(onDismiss).toHaveBeenCalled()
  })

  it('tells a member to ask an admin for the key instead of linking to a page they cannot open', () => {
    render(<MemoryRouter><I18nProvider><GettingStarted onDismiss={vi.fn()} steps={[{ id: 'key', done: false }]} /></I18nProvider></MemoryRouter>)
    expect(screen.queryByRole('link')).toBeNull()
    expect(screen.getByText('Ask an admin to add one.')).toBeTruthy()
  })
})
