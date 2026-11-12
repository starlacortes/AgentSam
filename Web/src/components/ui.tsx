import type { InputHTMLAttributes, ReactNode } from 'react'
import { dateLocale, useI18n } from '../i18n'

export function Logo() {
  return (
    <span className="logo">
      <span className="mark" aria-hidden="true">
        S
      </span>
      <span className="word">AgentSam</span>
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

export function formatDate(iso?: string): string {
  if (!iso) return '—'
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return '—'
  return date.toLocaleString(dateLocale(), { dateStyle: 'medium', timeStyle: 'short' })
}
