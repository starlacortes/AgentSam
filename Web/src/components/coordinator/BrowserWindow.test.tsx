import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { api } from '../../api/client'
import { I18nProvider } from '../../i18n'
import { BrowserWindow } from './BrowserWindow'

vi.mock('../../api/client', async (importOriginal) => ({ ...await importOriginal<typeof import('../../api/client')>(), api: vi.fn() }))

/** Stands in for noVNC: records how it was created and what was sent. */
const clients: FakeClient[] = []
class FakeClient extends EventTarget {
  keys: Array<[number, boolean | undefined]> = []
  disconnected = false
  scaleViewport = false
  resizeSession = true
  focusOnClick = false
  background = ''
  constructor(public target: HTMLElement, public url: string, public options: { credentials?: { password?: string } }) {
    super()
    clients.push(this)
  }
  sendKey(keysym: number, _code: string | null, down?: boolean) { this.keys.push([keysym, down]) }
  disconnect() { this.disconnected = true }
}
vi.mock('@novnc/novnc', () => ({ default: FakeClient }))

function open(onClose = vi.fn()) {
  render(<I18nProvider><BrowserWindow onClose={onClose} /></I18nProvider>)
  return onClose
}

describe('Ada’s browser window', () => {
  afterEach(() => { cleanup(); vi.clearAllMocks(); clients.length = 0 })

  it('starts the browser, connects on the app’s own address and goes live', async () => {
    vi.mocked(api).mockResolvedValue({ state: 'running', password: 'secret12' })
    open()
    expect(screen.getByRole('status', { name: '' }).textContent).toBe('Starting the browser…')
    await waitFor(() => expect(clients).toHaveLength(1))
    expect(api).toHaveBeenCalledWith('browser/start', { method: 'POST' })
    const client = clients[0]!
    expect(client.url).toMatch(/^ws:\/\/[^/]+\/api\/browser\/live$/)
    expect(client.options.credentials?.password).toBe('secret12')
    expect(client.scaleViewport).toBe(true)
    client.dispatchEvent(new Event('connect'))
    await screen.findByText('Live')
  })

  it('types text from the box, and sends Enter when the box is empty', async () => {
    vi.mocked(api).mockResolvedValue({ state: 'running', password: '' })
    open()
    await waitFor(() => expect(clients).toHaveLength(1))
    const client = clients[0]!
    client.dispatchEvent(new Event('connect'))
    await screen.findByText('Live')
    fireEvent.change(screen.getByLabelText('Text to type in the browser'), { target: { value: 'hi' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))
    expect(client.keys).toEqual([[0x68, true], [0x68, false], [0x69, true], [0x69, false]])
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))
    expect(client.keys.slice(4)).toEqual([[0xff0d, true], [0xff0d, false]])
  })

  it('says why when the browser cannot start, and offers to reconnect', async () => {
    vi.mocked(api).mockRejectedValue(new Error('The browser could not start on the workstation.'))
    open()
    expect((await screen.findByRole('alert')).textContent).toContain('could not start')
    expect(clients).toHaveLength(0)
    expect(screen.getByRole('button', { name: 'Reconnect' })).toBeTruthy()
  })

  it('stops the browser and closes', async () => {
    vi.mocked(api).mockResolvedValue({ state: 'running', password: '' })
    const onClose = open()
    await waitFor(() => expect(clients).toHaveLength(1))
    fireEvent.click(screen.getByRole('button', { name: 'Stop the browser' }))
    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(api).toHaveBeenCalledWith('browser/stop', { method: 'POST' })
    expect(clients[0]!.disconnected).toBe(true)
  })

  it('lets the person take over and hand back when Ada can drive, and only then accepts their input', async () => {
    vi.mocked(api).mockImplementation(async (path: string, init?: { body?: unknown }) => {
      if (path === 'browser/start') return { state: 'running', password: 'p', drivable: true, control: 'ada' }
      if (path === 'browser/control') return { control: (init?.body as { control: string }).control }
      return {}
    })
    open()
    await waitFor(() => expect(clients).toHaveLength(1))
    const client = clients[0]! as FakeClient & { viewOnly?: boolean }
    client.dispatchEvent(new Event('connect'))
    await screen.findByText('Ada is driving')
    expect(client.viewOnly).toBe(true)
    expect((screen.getByLabelText('Text to type in the browser') as HTMLInputElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Take over' }))
    await screen.findByText('You’re in control')
    expect(api).toHaveBeenCalledWith('browser/control', { method: 'POST', body: { control: 'person' } })
    expect(client.viewOnly).toBe(false)
    expect((screen.getByLabelText('Text to type in the browser') as HTMLInputElement).disabled).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: 'Hand back' }))
    await screen.findByText('Ada is driving')
    expect(client.viewOnly).toBe(true)
  })

  it('hands the browser back when the window closes while the person is in control', async () => {
    vi.mocked(api).mockImplementation(async (path: string, init?: { body?: unknown }) => {
      if (path === 'browser/start') return { state: 'running', password: 'p', drivable: true, control: 'person' }
      if (path === 'browser/control') return { control: (init?.body as { control: string }).control }
      return {}
    })
    open()
    await waitFor(() => expect(clients).toHaveLength(1))
    clients[0]!.dispatchEvent(new Event('connect'))
    await screen.findByText('You’re in control')
    cleanup()
    expect(api).toHaveBeenCalledWith('browser/control', { method: 'POST', body: { control: 'ada' } })
  })

  it('asks twice before erasing sign-ins', async () => {
    vi.mocked(api).mockImplementation(async (path: string) => {
      if (path === 'browser/start') return { state: 'running', password: 'p', drivable: true, control: 'ada' }
      return { control: 'ada' }
    })
    open()
    await waitFor(() => expect(clients).toHaveLength(1))
    fireEvent.click(await screen.findByRole('button', { name: 'Erase sign-ins' }))
    expect(api).not.toHaveBeenCalledWith('browser/erase', { method: 'POST' })
    fireEvent.click(screen.getByRole('button', { name: 'Press again to sign out of every site' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('browser/erase', { method: 'POST' }))
  })
})
