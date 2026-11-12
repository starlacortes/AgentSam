import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { I18nProvider } from '../../i18n'
import { VoiceMode } from './VoiceMode'

class TestUtterance {
  lang = ''
  onend: (() => void) | null = null
  onerror: (() => void) | null = null
  constructor(public text: string) {}
}

describe('VoiceMode', () => {
  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('keeps a keyboard fallback and sends to the real coordinator callback', async () => {
    const onSend = vi.fn().mockResolvedValue({ text: 'A **clear answer** from Ada.' })
    const onClose = vi.fn()
    const synthesis = { speak: vi.fn(), cancel: vi.fn() }
    vi.stubGlobal('SpeechSynthesisUtterance', TestUtterance)
    Object.defineProperty(window, 'speechSynthesis', { value: synthesis, configurable: true })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={onClose} /></I18nProvider>)
    expect(screen.getByText(/Voice recognition isn’t supported here/)).toBeTruthy()
    fireEvent.change(screen.getByRole('textbox', { name: 'Message Ada with your keyboard' }), { target: { value: '  Hello Ada  ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await waitFor(() => expect(onSend).toHaveBeenCalledWith('Hello Ada', true))
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(1))
    expect(synthesis.speak.mock.calls[0]?.[0].text).toBe('A clear answer from Ada.')
    fireEvent.click(screen.getAllByRole('button', { name: 'Return to chat' })[0]!)
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(synthesis.cancel).toHaveBeenCalled()
  })

  it('can mute spoken responses and cleanly dismiss the full-screen interface', async () => {
    const synthesis = { speak: vi.fn(), cancel: vi.fn() }
    vi.stubGlobal('SpeechSynthesisUtterance', TestUtterance)
    Object.defineProperty(window, 'speechSynthesis', { value: synthesis, configurable: true })
    render(<I18nProvider><VoiceMode onSend={vi.fn().mockResolvedValue({ text: 'Text response' })} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    fireEvent.click(screen.getByRole('button', { name: 'Mute Ada' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Message Ada with your keyboard' }), { target: { value: 'Hello' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await waitFor(() => expect(screen.getByText('Text response')).toBeTruthy())
    expect(synthesis.speak).not.toHaveBeenCalled()
  })
})
