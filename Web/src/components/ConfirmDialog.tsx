import { createContext, useCallback, useContext, useId, useMemo, useRef, useState, type ReactNode } from 'react'
import { useI18n } from '../i18n'
import { Icon } from './coordinator/Icon'
import { useDialogA11y } from './coordinator/Overlay'

export interface ConfirmOptions {
  /** The question, as a short sentence. */
  title: string
  /** What happens next, in a line or two. */
  detail?: string
  /** Words for the button that goes ahead, such as "Delete". */
  confirm: string
  /** Words for the button that backs out. "Cancel" unless that would be confusing. */
  cancel?: string
  /** Red button for something that removes or stops things. */
  danger?: boolean
}

export interface AskOptions {
  title: string
  detail?: string
  /** Label and placeholder for the one text box. */
  label: string
  confirm: string
  maxLength?: number
}

interface Dialogs {
  /** Ada's own "are you sure?" in place of the browser's. Resolves true when the person goes ahead. */
  confirm: (options: ConfirmOptions) => Promise<boolean>
  /** Asks for one short line of text. Resolves null when the person cancels. */
  ask: (options: AskOptions) => Promise<string | null>
}

type Open =
  | { kind: 'confirm'; options: ConfirmOptions; done: (ok: boolean) => void }
  | { kind: 'ask'; options: AskOptions; done: (text: string | null) => void }

// Outside a provider (a component rendered alone in a test) the browser's own dialogs still answer.
const fallback: Dialogs = {
  confirm: async (options) => window.confirm([options.title, options.detail].filter(Boolean).join('\n\n')),
  ask: async (options) => window.prompt(options.title)?.trim() || null,
}

const DialogContext = createContext<Dialogs>(fallback)

export function useDialogs(): Dialogs {
  return useContext(DialogContext)
}

/** Holds the one confirm or ask dialog that can be open at a time. */
export function DialogProvider({ children }: { children: ReactNode }) {
  const [open, setOpen] = useState<Open | null>(null)
  const current = useRef<Open | null>(null)
  const show = useCallback((next: Open) => {
    // A second request while one is open answers the first as "cancel".
    const before = current.current
    if (before) { if (before.kind === 'confirm') before.done(false); else before.done(null) }
    current.current = next
    setOpen(next)
  }, [])
  const close = useCallback(() => { current.current = null; setOpen(null) }, [])
  const dialogs = useMemo<Dialogs>(() => ({
    confirm: (options) => new Promise((resolve) => show({ kind: 'confirm', options, done: resolve })),
    ask: (options) => new Promise((resolve) => show({ kind: 'ask', options, done: resolve })),
  }), [show])

  return <DialogContext.Provider value={dialogs}>
    {children}
    {open?.kind === 'confirm' ? <ConfirmCard key="confirm" options={open.options} onDone={(ok) => { close(); open.done(ok) }} /> : null}
    {open?.kind === 'ask' ? <AskCard key="ask" options={open.options} onDone={(text) => { close(); open.done(text) }} /> : null}
  </DialogContext.Provider>
}

function ConfirmCard({ options, onDone }: { options: ConfirmOptions; onDone: (ok: boolean) => void }) {
  const { t } = useI18n()
  const ref = useRef<HTMLDivElement>(null)
  const titleID = useId()
  const detailID = useId()
  useDialogA11y(ref, () => onDone(false))
  return <div className="co-modal-overlay co-confirm-overlay" onClick={() => onDone(false)}>
    <div ref={ref} className="co-confirm" role="alertdialog" aria-modal="true" aria-labelledby={titleID} aria-describedby={options.detail ? detailID : undefined} onClick={(event) => event.stopPropagation()}>
      <h2 id={titleID}>{options.title}</h2>
      {options.detail ? <p id={detailID}>{options.detail}</p> : null}
      <div className="co-confirm-actions">
        {/* Cancel comes first so it takes focus: Enter never removes anything by accident. */}
        <button type="button" className="co-secondary-button" onClick={() => onDone(false)}>{options.cancel ?? t('Cancel')}</button>
        <button type="button" className={`co-primary-button ${options.danger ? 'danger' : ''}`} onClick={() => onDone(true)}>{options.confirm}</button>
      </div>
    </div>
  </div>
}

function AskCard({ options, onDone }: { options: AskOptions; onDone: (text: string | null) => void }) {
  const { t } = useI18n()
  const ref = useRef<HTMLFormElement>(null)
  const titleID = useId()
  const [text, setText] = useState('')
  useDialogA11y(ref, () => onDone(null))
  return <div className="co-modal-overlay co-confirm-overlay" onClick={() => onDone(null)}>
    <form ref={ref} className="co-confirm" role="dialog" aria-modal="true" aria-labelledby={titleID} onClick={(event) => event.stopPropagation()} onSubmit={(event) => { event.preventDefault(); if (text.trim()) onDone(text.trim()) }}>
      <h2 id={titleID}>{options.title}</h2>
      {options.detail ? <p>{options.detail}</p> : null}
      <input className="co-confirm-input" type="text" value={text} maxLength={options.maxLength ?? 80} aria-label={options.label} placeholder={options.label} autoComplete="off" onChange={(event) => setText(event.target.value)} />
      <div className="co-confirm-actions">
        <button type="button" className="co-secondary-button" onClick={() => onDone(null)}>{t('Cancel')}</button>
        <button type="submit" className="co-primary-button" disabled={!text.trim()}><Icon name="check" size={14} />{options.confirm}</button>
      </div>
    </form>
  </div>
}
