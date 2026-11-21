import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Icon, type IconName } from './Icon'

export interface PopMenuItem {
  label: string
  icon: IconName
  onSelect: () => void
  /** Small status text after the label, e.g. "On" or "Connected". */
  note?: string
  danger?: boolean
  disabled?: boolean
}

/**
 * A button that opens a short menu. It closes on a choice, Escape, or a tap outside.
 * `align` picks which edge of the button the menu lines up with; `up` opens it above the button.
 */
export function PopMenu({ label, icon, iconSize = 16, items, className = '', align = 'right', up = false, disabled = false, children }: { label: string; icon: IconName; iconSize?: number; items: PopMenuItem[]; className?: string; align?: 'left' | 'right'; up?: boolean; disabled?: boolean; children?: ReactNode }) {
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const close = (event: Event) => {
      if (event instanceof KeyboardEvent && event.key !== 'Escape') return
      if (event.type === 'pointerdown' && event.target instanceof Node && root.current?.contains(event.target)) return
      setOpen(false)
    }
    document.addEventListener('pointerdown', close)
    document.addEventListener('keydown', close)
    return () => {
      document.removeEventListener('pointerdown', close)
      document.removeEventListener('keydown', close)
    }
  }, [open])
  return (
    <div className={`co-popmenu ${className}`} ref={root}>
      <button type="button" className="co-icon-button" aria-label={label} title={label} aria-haspopup="menu" aria-expanded={open} disabled={disabled} onClick={() => setOpen((value) => !value)}>
        <Icon name={icon} size={iconSize} />
        {children}
      </button>
      {open ? (
        <div className={`co-popmenu-list ${align} ${up ? 'up' : 'down'}`} role="menu">
          {items.map((item) => (
            <button type="button" role="menuitem" key={item.label} className={item.danger ? 'danger' : ''} disabled={item.disabled} onClick={() => { setOpen(false); item.onSelect() }}>
              <Icon name={item.icon} size={15} />
              <span>{item.label}</span>
              {item.note ? <small>{item.note}</small> : null}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  )
}
