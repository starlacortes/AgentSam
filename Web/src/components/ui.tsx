import type { InputHTMLAttributes, ReactNode } from 'react'
import { dateLocale, useI18n } from '../i18n'

export function Logo() {
  return (
    <span className="logo">
      <span className="mark" aria-hidden="true">
        A
      </span>
      <span className="word">Ada</span>
    </span>
  )
}

export function Field({ label, hint, ...input }: { label: string; hint?: ReactNode } & InputHTMLAttributes<HTMLInputElement>) {
  return (
    <label className="field">
      <span>{label}</span>
      <input className="input" {...input} />
      {hint ? <small className="hint">{hint}</small> : null}
    </label>
  )
}

export function ErrorBanner({ message }: { message: string | null }) {
  if (!message) return null
  return (
    <div className="error" role="alert">
      {message}
    </div>
  )
}

export function Spinner({ label }: { label?: string }) {
  const { t } = useI18n()
  return <span className="spin" role="status" aria-label={label ?? t('Loading')} />
}

/** A date short enough for a table cell: "Nov 24, 6:09 AM", with the year only when it is not this one. */
export function formatShortDate(iso?: string, now = new Date()): string {
  if (!iso) return '—'
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return '—'
  const sameYear = date.getFullYear() === now.getFullYear()
  return date.toLocaleString(dateLocale(), sameYear
    ? { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }
    : { month: 'short', day: 'numeric', year: 'numeric' })
}

export function formatDate(iso?: string): string {
  if (!iso) return '—'
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return '—'
  return date.toLocaleString(dateLocale(), { dateStyle: 'medium', timeStyle: 'short' })
}
