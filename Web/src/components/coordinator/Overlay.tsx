import { useEffect, useRef, type ReactNode, type RefObject } from 'react'
import { useI18n } from '../../i18n'
import { Icon } from './Icon'

export function useDialogA11y(ref: RefObject<HTMLElement | null>, onClose: () => void) {
  const close = useRef(onClose)
  close.current = onClose
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    const oldOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    const focusable = () => [...(ref.current?.querySelectorAll<HTMLElement>('button:not([disabled]), a[href], input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex="0"]') ?? [])]
    focusable()[0]?.focus()
    const keydown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        close.current()
      }
      if (event.key !== 'Tab') return
      const items = focusable()
      if (items.length === 0) return
      const first = items[0]
      const last = items[items.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last?.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first?.focus()
      }
    }
    document.addEventListener('keydown', keydown)
    return () => {
      document.body.style.overflow = oldOverflow
      document.removeEventListener('keydown', keydown)
      previous?.focus()
    }
  }, [ref])
}

export function Drawer({ title, eyebrow, description, onClose, children }: { title: string; eyebrow: string; description: string; onClose: () => void; children: ReactNode }) {
  const { t } = useI18n()
  const ref = useRef<HTMLElement>(null)
  useDialogA11y(ref, onClose)
  return <>
    <div className="co-scrim" onClick={onClose} />
    <aside className="co-drawer" ref={ref} role="dialog" aria-modal="true" aria-labelledby="co-drawer-title">
      <div className="co-drawer-head">
        <div><span className="co-kicker">{eyebrow}</span><h2 id="co-drawer-title">{title}</h2><p>{description}</p></div>
        <button className="co-icon-button" aria-label={t('Close')} onClick={onClose}><Icon name="close" /></button>
      </div>
      <div className="co-drawer-body">{children}</div>
    </aside>
  </>
}
