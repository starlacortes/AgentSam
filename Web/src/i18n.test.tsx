import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { I18nProvider, translate, useI18n } from './i18n'
import { LanguageToggle } from './components/Layout'

function Probe() {
  const { t } = useI18n()
  return <span>{t('Sign out')}</span>
}

describe('i18n', () => {
  afterEach(() => {
    cleanup()
    localStorage.clear()
  })

  it('interpolates variables and falls back to English for unknown keys', () => {
    expect(translate('by {name}', { name: 'Ada' })).toBe('by Ada')
    expect(translate('Some untranslated string')).toBe('Some untranslated string')
  })

  it('switches language instantly from the toolbar toggle and persists the choice', () => {
    render(
      <I18nProvider>
        <LanguageToggle />
        <Probe />
      </I18nProvider>,
    )
    expect(screen.getByText('Sign out')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'ES' }))
    expect(screen.getByText('Cerrar sesión')).toBeTruthy()
    expect(localStorage.getItem('agentsam.lang')).toBe('es')
    expect(document.documentElement.lang).toBe('es')
    expect(translate('Sign out')).toBe('Cerrar sesión')

    fireEvent.click(screen.getByRole('button', { name: 'EN' }))
    expect(screen.getByText('Sign out')).toBeTruthy()
    expect(localStorage.getItem('agentsam.lang')).toBe('en')
  })
})
