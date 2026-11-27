import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { I18nProvider } from '../i18n'
import { DialogProvider, useDialogs } from './ConfirmDialog'

function Harness({ onAnswer }: { onAnswer: (value: unknown) => void }) {
  const dialogs = useDialogs()
  return <>
    <button onClick={() => void dialogs.confirm({ title: 'Delete this conversation?', detail: 'Its messages will be removed.', confirm: 'Delete', danger: true }).then(onAnswer)}>ask-confirm</button>
    <button onClick={() => void dialogs.ask({ title: 'New project', label: 'Project name', confirm: 'Create project' }).then(onAnswer)}>ask-name</button>
  </>
}

function setup() {
  const onAnswer = vi.fn()
  render(<I18nProvider><DialogProvider><Harness onAnswer={onAnswer} /></DialogProvider></I18nProvider>)
  return onAnswer
}

describe('Ada’s own dialogs', () => {
  afterEach(cleanup)

  it('goes ahead only when the person presses the action button', async () => {
    const onAnswer = setup()
    fireEvent.click(screen.getByText('ask-confirm'))
    expect(screen.getByRole('alertdialog', { name: 'Delete this conversation?' })).toBeTruthy()
    // Cancel has focus, so a stray Enter never deletes.
    expect(document.activeElement?.textContent).toBe('Cancel')
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    await waitFor(() => expect(onAnswer).toHaveBeenCalledWith(true))
    expect(screen.queryByRole('alertdialog')).toBeNull()
  })

  it('answers no on Cancel, Escape and a click outside', async () => {
    const onAnswer = setup()
    fireEvent.click(screen.getByText('ask-confirm'))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await waitFor(() => expect(onAnswer).toHaveBeenLastCalledWith(false))
    fireEvent.click(screen.getByText('ask-confirm'))
    fireEvent.keyDown(document, { key: 'Escape' })
    await waitFor(() => expect(onAnswer).toHaveBeenCalledTimes(2))
    expect(onAnswer).toHaveBeenLastCalledWith(false)
  })

  it('asks for a name and trims it', async () => {
    const onAnswer = setup()
    fireEvent.click(screen.getByText('ask-name'))
    const create = screen.getByRole('button', { name: 'Create project' }) as HTMLButtonElement
    expect(create.disabled).toBe(true)
    fireEvent.change(screen.getByLabelText('Project name'), { target: { value: '  Kitchen remodel ' } })
    fireEvent.click(create)
    await waitFor(() => expect(onAnswer).toHaveBeenCalledWith('Kitchen remodel'))
  })
})
