import { useEffect, useRef, useState, type FormEvent } from 'react'
import { api, errorMessage } from '../../api/client'
import type { Conversation, ConversationTrigger } from '../../api/types'
import { intervalLabel } from '../../api/types'
import { Icon } from './Icon'
import { ErrorBanner } from '../ui'
import { useI18n } from '../../i18n'

const INTERVALS = [15, 30, 60, 360, 720, 1440] as const
const WEEKDAYS = [1, 2, 3, 4, 5]
const WEEKENDS = [6, 7]

/** Short local weekday names, Monday first (1 January 2024 was a Monday). */
function dayNames(lang: string): string[] {
  const format = new Intl.DateTimeFormat(lang, { weekday: 'short', timeZone: 'UTC' })
  return [0, 1, 2, 3, 4, 5, 6].map((offset) => format.format(new Date(Date.UTC(2024, 0, 1 + offset))))
}

function sameDays(a: number[], b: number[]): boolean {
  return a.length === b.length && a.every((day, index) => day === b[index])
}

/** Days as the server reads them: "every day", or "mon,wed,fri". */
function daysParam(days: number[]): string {
  const names = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']
  return days.length === 0 || days.length === 7 ? 'every day' : days.map((day) => names[day - 1]).join(',')
}

function timeZoneName(): string | undefined {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone } catch { return undefined }
}

/**
 * A chat's automation: one schedule (every N minutes, or at a set time on chosen days) and
 * triggers that wake the chat when something happens (new matching email, a webhook call).
 * Each run is sent for the user, and Ada runs it with her normal tools.
 */
export function ScheduleModal({ conversation, onUpdated, onClose, gmailConnected = false }: { conversation: Conversation; onUpdated: (conversation: Conversation) => void; onClose: () => void; gmailConnected?: boolean }) {
  const { t, lang } = useI18n()
  const schedule = conversation.schedule ?? null
  const [prompt, setPrompt] = useState(schedule?.prompt ?? '')
  const [mode, setMode] = useState<'interval' | 'time'>(schedule?.at ? 'time' : 'interval')
  const [interval, setInterval] = useState<number>(schedule?.at ? 60 : schedule?.intervalMinutes ?? 60)
  const [clock, setClock] = useState(schedule?.at ? `${String(schedule.at.hour).padStart(2, '0')}:${String(schedule.at.minute).padStart(2, '0')}` : '08:00')
  const [days, setDays] = useState<number[]>(schedule?.at?.weekdays ?? WEEKDAYS)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const field = useRef<HTMLTextAreaElement>(null)
  const names = dayNames(lang)

  useEffect(() => {
    const escape = (event: globalThis.KeyboardEvent) => { if (event.key === 'Escape') onClose() }
    window.addEventListener('keydown', escape)
    window.setTimeout(() => field.current?.focus(), 0)
    return () => window.removeEventListener('keydown', escape)
  }, [onClose])

  const run = async (work: () => Promise<Conversation>, close = false): Promise<boolean> => {
    if (saving) return false
    setSaving(true)
    setError(null)
    try {
      onUpdated(await work())
      if (close) onClose()
      return true
    } catch (err) { setError(errorMessage(err)); return false } finally { setSaving(false) }
  }

  const submit = (event: FormEvent) => {
    event.preventDefault()
    const text = prompt.trim()
    if (!text) return
    const body = mode === 'time'
      ? { prompt: text, at: clock, days: daysParam(days), language: lang, timeZone: timeZoneName() }
      : { prompt: text, intervalMinutes: interval, language: lang, timeZone: timeZoneName() }
    void run(() => api<Conversation>(`conversations/${conversation.id}/schedule`, { method: 'PUT', body }), true)
  }

  const cancel = () => void run(() => api<Conversation>(`conversations/${conversation.id}/schedule`, { method: 'DELETE' }), true)

  const toggleDay = (day: number) => setDays((current) => current.includes(day) ? current.filter((value) => value !== day) : [...current, day].sort())

  const when = (iso: string) => new Date(iso).toLocaleString([], { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' })

  return <div className="co-modal-overlay" role="dialog" aria-modal="true" aria-label={t('Automation')} onClick={onClose}>
    <div className="co-modal co-schedule-modal" onClick={(event) => event.stopPropagation()}>
      <div className="co-drawer-head">
        <Icon name="refresh" size={22} />
        <div>
          <span className="co-kicker">{t('Automation')}</span>
          <h2>{t('Run without being asked')}</h2>
          <p>{t('The server sends a prompt for you on a schedule or when something happens, and Ada runs it with her normal tools. Each run appears in the chat, labeled as automatic.')}</p>
        </div>
        <button className="co-icon-button" aria-label={t('Close')} onClick={onClose}><Icon name="close" /></button>
      </div>
      <form className="co-schedule-body" onSubmit={submit}>
        <h3 className="co-automation-heading">{t('Schedule')}</h3>
        {schedule?.pausedAt ? <div className="co-automation-paused" role="status">
          <span>{t('Paused after {count} failed runs in a row.', { count: String(schedule.failures ?? 3) })}</span>
        </div> : null}
        <label className="co-schedule-field">
          <span>{t('Prompt to run')}</span>
          <textarea ref={field} value={prompt} onChange={(event) => setPrompt(event.target.value)} rows={3} maxLength={4000} placeholder={t('Refresh the list and update the saved file with anything new')} disabled={saving} />
        </label>
        <div className="co-schedule-field">
          <span>{t('When')}</span>
          <div className="co-schedule-intervals" role="group" aria-label={t('When')}>
            <button type="button" className={mode === 'interval' ? 'active' : ''} aria-pressed={mode === 'interval'} onClick={() => setMode('interval')} disabled={saving}>{t('Every few minutes or hours')}</button>
            <button type="button" className={mode === 'time' ? 'active' : ''} aria-pressed={mode === 'time'} onClick={() => setMode('time')} disabled={saving}>{t('At a set time')}</button>
          </div>
        </div>
        {mode === 'interval' ? <label className="co-schedule-field">
          <span>{t('How often')}</span>
          <div className="co-schedule-intervals">
            {INTERVALS.map((minutes) => (
              <button key={minutes} type="button" className={interval === minutes ? 'active' : ''} onClick={() => setInterval(minutes)} disabled={saving}>{t(intervalLabel(minutes))}</button>
            ))}
          </div>
        </label> : <>
          <label className="co-schedule-field">
            <span>{t('Time')}</span>
            <input className="co-schedule-time" type="time" value={clock} onChange={(event) => setClock(event.target.value)} required disabled={saving} />
          </label>
          <div className="co-schedule-field">
            <span>{t('Days')}</span>
            <div className="co-schedule-intervals">
              <button type="button" className={sameDays(days, WEEKDAYS) ? 'active' : ''} onClick={() => setDays(WEEKDAYS)} disabled={saving}>{t('Weekdays')}</button>
              <button type="button" className={sameDays(days, WEEKENDS) ? 'active' : ''} onClick={() => setDays(WEEKENDS)} disabled={saving}>{t('Weekends')}</button>
              <button type="button" className={days.length === 0 || days.length === 7 ? 'active' : ''} onClick={() => setDays([])} disabled={saving}>{t('Every day')}</button>
            </div>
            <div className="co-schedule-days">
              {names.map((name, index) => {
                const day = index + 1
                const on = days.length === 0 || days.includes(day)
                return <button key={day} type="button" className={on ? 'active' : ''} aria-pressed={on} onClick={() => days.length === 0 ? setDays([1, 2, 3, 4, 5, 6, 7].filter((value) => value !== day)) : toggleDay(day)} disabled={saving}>{name}</button>
              })}
            </div>
          </div>
        </>}
        <ErrorBanner message={error} />
        <div className="co-schedule-actions">
          {schedule ? <button type="button" className="co-secondary-button" onClick={cancel} disabled={saving}>{t('Stop schedule')}</button> : null}
          <span className="co-schedule-note">
            {schedule && !schedule.pausedAt
              ? t('Next run {time}', { time: when(schedule.nextRunAt) })
              : mode === 'time' ? t('Times are in your time zone.') : t('The first run fires at the next interval boundary.')}
          </span>
          <button type="submit" className="co-primary-button" disabled={saving || !prompt.trim() || (mode === 'time' && !clock)}>{schedule?.pausedAt ? t('Resume schedule') : schedule ? t('Update schedule') : t('Schedule it')}</button>
        </div>
      </form>
      <TriggersSection conversation={conversation} gmailConnected={gmailConnected} busy={saving} run={run} />
    </div>
  </div>
}

function TriggersSection({ conversation, gmailConnected, busy, run }: { conversation: Conversation; gmailConnected: boolean; busy: boolean; run: (work: () => Promise<Conversation>) => Promise<boolean> }) {
  const { t, lang } = useI18n()
  const triggers = conversation.triggers ?? []
  const [kind, setKind] = useState<'gmail' | 'webhook'>(gmailConnected ? 'gmail' : 'webhook')
  const [prompt, setPrompt] = useState('')
  const [query, setQuery] = useState('')
  const [copied, setCopied] = useState<string | null>(null)
  const full = triggers.length >= 5

  const add = (event: FormEvent) => {
    event.preventDefault()
    if (!prompt.trim() || (kind === 'gmail' && !query.trim())) return
    void run(() => api<Conversation>(`conversations/${conversation.id}/triggers`, { method: 'POST', body: { kind, prompt: prompt.trim(), query: kind === 'gmail' ? query.trim() : undefined, language: lang } }))
      .then((ok) => { if (ok) { setPrompt(''); setQuery('') } })
  }

  const address = (trigger: ConversationTrigger) => `${window.location.origin}/api/hooks/${trigger.token ?? ''}`

  const copy = (trigger: ConversationTrigger) => {
    void navigator.clipboard?.writeText(address(trigger)).then(() => {
      setCopied(trigger.id)
      window.setTimeout(() => setCopied(null), 1400)
    })
  }

  return <form className="co-schedule-body co-automation-triggers" onSubmit={add}>
    <h3 className="co-automation-heading">{t('Triggers')}</h3>
    <p className="co-schedule-note">{t('Run a prompt when something happens. Each trigger runs at most 6 times an hour and pauses itself after 3 failed runs in a row.')}</p>
    {triggers.length ? <ul className="co-trigger-list">
      {triggers.map((trigger) => <li key={trigger.id} className={trigger.pausedAt ? 'paused' : ''}>
        <div className="co-trigger-main">
          <b>{trigger.kind === 'gmail' ? t('New email matching {query}', { query: trigger.query ?? '' }) : t('Webhook call')}</b>
          <span>{trigger.prompt}</span>
          {trigger.kind === 'webhook' ? <span className="co-trigger-address">
            <code>{address(trigger)}</code>
            <button type="button" className="co-icon-button" aria-label={t('Copy webhook address')} onClick={() => copy(trigger)}><Icon name={copied === trigger.id ? 'check' : 'copy'} size={13} /></button>
          </span> : null}
          {trigger.pausedAt ? <span className="co-automation-paused">{t('Paused after {count} failed runs in a row.', { count: String(trigger.failures ?? 3) })}</span>
            : trigger.lastFiredAt ? <span className="co-schedule-note">{t('Last ran {time}', { time: new Date(trigger.lastFiredAt).toLocaleString([], { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' }) })}</span> : null}
        </div>
        <div className="co-trigger-actions">
          {trigger.pausedAt ? <button type="button" className="co-secondary-button" disabled={busy} onClick={() => void run(() => api<Conversation>(`conversations/${conversation.id}/triggers/${trigger.id}/resume`, { method: 'POST' }))}>{t('Resume')}</button> : null}
          <button type="button" className="co-icon-button" aria-label={t('Remove trigger')} disabled={busy} onClick={() => void run(() => api<Conversation>(`conversations/${conversation.id}/triggers/${trigger.id}`, { method: 'DELETE' }))}><Icon name="trash" size={14} /></button>
        </div>
      </li>)}
    </ul> : null}
    {full ? null : <>
      <div className="co-schedule-intervals" role="group" aria-label={t('Trigger type')}>
        <button type="button" className={kind === 'gmail' ? 'active' : ''} aria-pressed={kind === 'gmail'} onClick={() => setKind('gmail')} disabled={busy || !gmailConnected} title={gmailConnected ? undefined : t('Connect Gmail in Settings first')}>{t('New email')}</button>
        <button type="button" className={kind === 'webhook' ? 'active' : ''} aria-pressed={kind === 'webhook'} onClick={() => setKind('webhook')} disabled={busy}>{t('Webhook')}</button>
      </div>
      {kind === 'gmail' ? <label className="co-schedule-field">
        <span>{t('Gmail search')}</span>
        <input className="co-schedule-input" value={query} onChange={(event) => setQuery(event.target.value)} maxLength={500} placeholder="from:billing@example.com has:attachment" disabled={busy} />
      </label> : <p className="co-schedule-note">{t('You get a private address. Anything that sends a POST to it starts a run, with the request body attached. Keep the address secret.')}</p>}
      <label className="co-schedule-field">
        <span>{t('Prompt to run')}</span>
        <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} rows={2} maxLength={4000} placeholder={kind === 'gmail' ? t('Summarize the new email and add it to invoices.csv') : t('Tell me how the deploy went')} disabled={busy} />
      </label>
      <div className="co-schedule-actions">
        <button type="submit" className="co-primary-button" disabled={busy || !prompt.trim() || (kind === 'gmail' && !query.trim())}>{t('Add trigger')}</button>
      </div>
    </>}
  </form>
}
