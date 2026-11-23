import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { I18nProvider } from '../../i18n'
import { fallbackAck, progressCue, startedOver, VoiceMode, type VoicePartial } from './VoiceMode'

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
    const reply = 'A **clear answer** from Ada.'
    const onSend = vi.fn(async (_text: string, _wait: boolean, onPartial?: (update: { text: string; final: boolean; speechPath: string }) => void) => {
      onPartial?.({ text: reply, final: true, speechPath: '/speech' })
      return { text: reply }
    })
    const onClose = vi.fn()
    const synthesis = { speak: vi.fn(), cancel: vi.fn() }
    vi.stubGlobal('SpeechSynthesisUtterance', TestUtterance)
    Object.defineProperty(window, 'speechSynthesis', { value: synthesis, configurable: true })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={onClose} /></I18nProvider>)
    expect(screen.getByText(/Voice recognition isn’t supported here/)).toBeTruthy()
    fireEvent.change(screen.getByRole('textbox', { name: 'Message Ada with your keyboard' }), { target: { value: '  Hello Ada  ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await waitFor(() => expect(onSend).toHaveBeenCalledWith('Hello Ada', true, expect.any(Function), true))
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

  it('replays Ada’s last spoken answer, even after she was muted', async () => {
    const reply = 'Your total is ready.'
    const onSend = vi.fn(async (_text: string, _wait: boolean, onPartial?: (update: { text: string; final: boolean; speechPath: string }) => void) => {
      onPartial?.({ text: reply, final: true, speechPath: '/speech' })
      return { text: reply }
    })
    const synthesis = { speak: vi.fn((utterance: TestUtterance) => { window.setTimeout(() => utterance.onend?.(), 0) }), cancel: vi.fn(), resume: vi.fn() }
    vi.stubGlobal('SpeechSynthesisUtterance', TestUtterance)
    Object.defineProperty(window, 'speechSynthesis', { value: synthesis, configurable: true })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    expect(screen.queryByRole('button', { name: 'Replay answer' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Mute Ada' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Message Ada with your keyboard' }), { target: { value: 'Hello' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    const replay = await screen.findByRole('button', { name: 'Replay answer' })
    expect(synthesis.speak).not.toHaveBeenCalled()
    fireEvent.click(replay)
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(1))
    expect(synthesis.speak.mock.calls[0]?.[0].text).toBe(reply)
    await screen.findByRole('button', { name: 'Replay answer' })
    fireEvent.click(screen.getByRole('button', { name: 'Replay answer' }))
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(2))
  })

  it('shows what Ada is doing under the orb only while she works', () => {
    const synthesis = { speak: vi.fn(), cancel: vi.fn() }
    vi.stubGlobal('SpeechSynthesisUtterance', TestUtterance)
    Object.defineProperty(window, 'speechSynthesis', { value: synthesis, configurable: true })
    const props = { onSend: vi.fn(), onTranscribe: vi.fn(), onClose: vi.fn() }
    const view = render(<I18nProvider><VoiceMode {...props} activity={null} /></I18nProvider>)
    const status = () => view.container.querySelector('.co-voice-status')!
    expect(status().classList.contains('on')).toBe(false)
    expect(status().textContent).toBe('')
    view.rerender(<I18nProvider><VoiceMode {...props} activity="Searching Gmail" /></I18nProvider>)
    expect(status().classList.contains('on')).toBe(true)
    expect(status().textContent).toBe('Searching Gmail')
    view.rerender(<I18nProvider><VoiceMode {...props} activity={null} /></I18nProvider>)
    expect(status().classList.contains('on')).toBe(false)
  })
})

class TestRecognition {
  static made: TestRecognition[] = []
  continuous = false
  interimResults = false
  lang = ''
  onresult: ((event: { results: ArrayLike<{ isFinal: boolean; 0: { transcript: string } }> }) => void) | null = null
  onerror: ((event: { error?: string }) => void) | null = null
  onend: (() => void) | null = null
  start = vi.fn()
  stop = vi.fn(() => this.onend?.())
  abort = vi.fn()
  constructor() { TestRecognition.made.push(this) }
  say(text: string) { this.onresult?.({ results: [{ isFinal: true, 0: { transcript: text } }] }) }
}

describe('VoiceMode hands-free', () => {
  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
    vi.useRealTimers()
    TestRecognition.made = []
  })

  function setUp(speak: (utterance: TestUtterance) => void = (utterance) => { window.setTimeout(() => utterance.onend?.(), 0) }) {
    const synthesis = { speak: vi.fn(speak), cancel: vi.fn(), resume: vi.fn() }
    vi.stubGlobal('SpeechSynthesisUtterance', TestUtterance)
    vi.stubGlobal('webkitSpeechRecognition', TestRecognition)
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('offline')))
    Object.defineProperty(window, 'speechSynthesis', { value: synthesis, configurable: true })
    return synthesis
  }

  it('starts listening as soon as voice mode opens', async () => {
    setUp()
    render(<I18nProvider><VoiceMode onSend={vi.fn()} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(1))
    expect(TestRecognition.made[0]!.start).toHaveBeenCalledTimes(1)
    expect(screen.getByText('Listening…')).toBeTruthy()
    expect(document.querySelector('.co-voice-orb')!.classList.contains('listening')).toBe(true)
  })

  it('closes the microphone quietly when nothing is said', async () => {
    setUp()
    render(<I18nProvider><VoiceMode onSend={vi.fn()} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(1))
    act(() => TestRecognition.made[0]!.onerror?.({ error: 'no-speech' }))
    expect(screen.getByText('I stopped listening. Tap the orb when you’re ready.')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('sends what was said, speaks the answer, then stays quiet until tapped', async () => {
    let finishSpeaking = () => {}
    const synthesis = setUp((utterance) => { finishSpeaking = () => utterance.onend?.() })
    const onSend = vi.fn(async (_text: string, _wait: boolean, onPartial?: (update: { text: string; final: boolean; speechPath: string }) => void) => {
      onPartial?.({ text: 'It is sunny.', final: true, speechPath: '/speech' })
      return { text: 'It is sunny.' }
    })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(1))
    const first = TestRecognition.made[0]!
    act(() => first.say('What is the weather'))
    act(() => first.onend?.())
    await waitFor(() => expect(onSend).toHaveBeenCalledWith('What is the weather', true, expect.any(Function), true))
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(1))
    await screen.findByText('Speaking')
    // The microphone stays closed while Ada talks…
    expect(TestRecognition.made).toHaveLength(1)
    act(() => finishSpeaking())
    // …and after she finishes, she doesn't start listening again on her own.
    await screen.findByText('Tap the orb to reply.')
    expect(TestRecognition.made).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Replay answer' })).toBeTruthy()
  })

  it('cuts Ada off and listens when the orb is tapped while she speaks', async () => {
    const synthesis = setUp(() => {})
    const onSend = vi.fn(async (_text: string, _wait: boolean, onPartial?: (update: { text: string; final: boolean; speechPath: string }) => void) => {
      onPartial?.({ text: 'A long answer.', final: true, speechPath: '/speech' })
      return { text: 'A long answer.' }
    })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(1))
    act(() => TestRecognition.made[0]!.onerror?.({ error: 'no-speech' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Message Ada with your keyboard' }), { target: { value: 'Tell me a story' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    const orb = await screen.findByRole('button', { name: 'Stop Ada and talk' })
    fireEvent.click(orb)
    expect(synthesis.cancel).toHaveBeenCalled()
    // The microphone opens a moment later, once the speakers are quiet.
    expect(TestRecognition.made).toHaveLength(1)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(2))
    expect(TestRecognition.made[1]!.start).toHaveBeenCalled()
  })

  it('stops talking for the rest of a reply still being written when the orb is tapped', async () => {
    const synthesis = setUp(() => {})
    let push: (update: { text: string; final: boolean; speechPath: string }) => void = () => {}
    let finish: () => void = () => {}
    const onSend = vi.fn((_text: string, _wait: boolean, onPartial?: (update: { text: string; final: boolean; speechPath: string }) => void) => {
      push = onPartial ?? (() => {})
      return new Promise<{ text: string }>((resolve) => { finish = () => resolve({ text: 'Here is the first part of the answer, read aloud right away. And here comes the second part of it.' }) })
    })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(1))
    act(() => TestRecognition.made[0]!.onerror?.({ error: 'no-speech' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Message Ada with your keyboard' }), { target: { value: 'Go' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    act(() => push({ text: 'Here is the first part of the answer, read aloud right away. And here comes', final: false, speechPath: '/speech' }))
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(1))
    await screen.findByText('Speaking')
    const orb = document.querySelector('.co-voice-orb')!
    expect(orb.getAttribute('aria-label')).toBe('Stop speaking')
    fireEvent.click(orb)
    act(() => push({ text: 'Here is the first part of the answer, read aloud right away. And here comes the second part of it.', final: true, speechPath: '/speech' }))
    await act(async () => finish())
    // The second sentence stays on screen but isn't read, and the microphone didn't open mid-reply.
    expect(synthesis.speak).toHaveBeenCalledTimes(1)
    expect(TestRecognition.made).toHaveLength(1)
  })

  it('closes the microphone when they start typing, and keeps what they typed', async () => {
    setUp()
    render(<I18nProvider><VoiceMode onSend={vi.fn()} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(1))
    const box = screen.getByRole('textbox', { name: 'Message Ada with your keyboard' })
    fireEvent.change(box, { target: { value: 'Typed instead' } })
    expect(TestRecognition.made[0]!.abort).toHaveBeenCalled()
    expect((box as HTMLInputElement).value).toBe('Typed instead')
    expect(document.querySelector('.co-voice-orb')!.classList.contains('idle')).toBe(true)
  })

  it('says a quick acknowledgement while Ada works, but keeps it out of Replay', async () => {
    let clock = 1_000_000
    vi.spyOn(Date, 'now').mockImplementation(() => clock)
    const synthesis = setUp()
    let push: (update: VoicePartial) => void = () => {}
    let finish: () => void = () => {}
    const onSend = vi.fn((_text: string, _wait: boolean, onPartial?: (update: VoicePartial) => void) => {
      push = onPartial ?? (() => {})
      return new Promise<{ text: string }>((resolve) => { finish = () => resolve({ text: 'You have two meetings tomorrow.' }) })
    })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={vi.fn()} /></I18nProvider>)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(1))
    act(() => TestRecognition.made[0]!.onerror?.({ error: 'no-speech' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Message Ada with your keyboard' }), { target: { value: 'What is on tomorrow' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    const partial = { text: '', final: false, speechPath: '/speech', ack: 'Let me check your calendar.' }
    // Too soon: an instant answer shouldn't get filler in front of it.
    act(() => push(partial))
    expect(synthesis.speak).not.toHaveBeenCalled()
    clock += 1200
    act(() => push(partial))
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(1))
    expect(synthesis.speak.mock.calls[0]?.[0].text).toBe('Let me check your calendar.')
    // Said once, not on every update.
    clock += 500
    act(() => push(partial))
    act(() => push({ ...partial, text: 'You have two meetings tomorrow.', final: true }))
    await act(async () => finish())
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(2))
    expect(synthesis.speak.mock.calls[1]?.[0].text).toBe('You have two meetings tomorrow.')
    fireEvent.click(await screen.findByRole('button', { name: 'Replay answer' }))
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(3))
    expect(synthesis.speak.mock.calls[2]?.[0].text).toBe('You have two meetings tomorrow.')
  })

  it('falls back to its own acknowledgement, then a progress line on long work', async () => {
    let clock = 1_000_000
    vi.spyOn(Date, 'now').mockImplementation(() => clock)
    const synthesis = setUp()
    let push: (update: VoicePartial) => void = () => {}
    const onSend = vi.fn((_text: string, _wait: boolean, onPartial?: (update: VoicePartial) => void) => {
      push = onPartial ?? (() => {})
      return new Promise<{ text: string }>(() => {})
    })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={vi.fn()} activity="Searching Gmail" /></I18nProvider>)
    await waitFor(() => expect(TestRecognition.made).toHaveLength(1))
    act(() => TestRecognition.made[0]!.onerror?.({ error: 'no-speech' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Message Ada with your keyboard' }), { target: { value: 'Find the invoice' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    const partial = { text: '', final: false, speechPath: '/speech' }
    clock += 1500
    act(() => push(partial))
    expect(synthesis.speak).not.toHaveBeenCalled()
    clock += 1500
    act(() => push(partial))
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(1))
    clock += 13_000
    act(() => push(partial))
    await waitFor(() => expect(synthesis.speak).toHaveBeenCalledTimes(2))
    expect(synthesis.speak.mock.calls[1]?.[0].text).toBe('Still on it, searching Gmail.')
    // The same step again isn't repeated.
    clock += 13_000
    act(() => push(partial))
    expect(synthesis.speak).toHaveBeenCalledTimes(2)
  })

  it('shows the conversation beside the orb, and sends picks from it through voice', async () => {
    setUp()
    const onSend = vi.fn().mockResolvedValue({ text: 'Done.' })
    render(<I18nProvider><VoiceMode onSend={onSend} onTranscribe={vi.fn()} onClose={vi.fn()} transcript={(voice) => <button onClick={() => voice.send('Yes, go ahead')}>Quick reply</button>} /></I18nProvider>)
    expect(screen.getByRole('complementary', { name: 'Conversation' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Quick reply' }))
    await waitFor(() => expect(onSend).toHaveBeenCalledWith('Yes, go ahead', true, expect.any(Function), false))
  })
})

describe('spoken filler', () => {
  it('varies the fallback acknowledgement and speaks Spanish too', () => {
    const first = fallbackAck('en')
    expect(fallbackAck('en')).not.toBe(first)
    expect(fallbackAck('es')).toMatch(/[a-záéíóú]/i)
    expect(progressCue('es', 'Buscando en Gmail')).toBe('Sigo en ello: buscando en Gmail.')
    expect(progressCue('en', null)).toBe('Still working on it.')
  })
})

describe('startedOver', () => {
  it('spots a reply that was cleared or replaced before a tool call', () => {
    expect(startedOver('', 'Anything')).toBe(false)
    expect(startedOver('Let me check that for you.', 'Let me check that for you. Then more')).toBe(false)
    expect(startedOver('Let me check that for you.', '')).toBe(true)
    expect(startedOver('Let me check that for you.', 'Revenue is up twelve percent.')).toBe(true)
    expect(startedOver('Short answer. ', 'Short answer.')).toBe(false)
  })
})
