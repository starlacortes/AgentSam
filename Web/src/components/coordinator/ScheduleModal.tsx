import { useEffect, useRef, useState, type FormEvent } from 'react'
import { api, errorMessage } from '../../api/client'
import type { Conversation } from '../../api/types'
import { intervalLabel } from '../../api/types'
import { Icon } from './Icon'
import { ErrorBanner } from '../ui'
import { useI18n } from '../../i18n'

const INTERVALS = [15, 30, 60, 360, 720, 1440] as const

/**
 * Sets or clears a conversation's recurring schedule: a prompt the server sends on a timer,
 * so Ada runs periodic work (an hourly refresh, a daily digest) without being asked each time.
 */
export function ScheduleModal({ conversation, onUpdated, onClose }: { conversation: Conversation; onUpdated: (conversation: Conversation) => void; onClose: () => void }) {
  const { t, lang } = useI18n()
  const schedule = conversation.schedule ?? null
  const [prompt, setPrompt] = useState(schedule?.prompt ?? '')
  const [interval, setInterval] = useState<number>(schedule?.intervalMinutes ?? 60)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const field = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    const escape = (event: globalThis.KeyboardEvent) => { if (event.key === 'Escape') onClose() }
    window.addEventListener('keydown', escape)
    window.setTimeout(() => field.current?.focus(), 0)
    return () => window.removeEventListener('keydown', escape)
  }, [onClose])

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    const text = prompt.trim()
    if (!text || saving) return
    setSaving(true)
    setError(null)
    try {
      onUpdated(await api<Conversation>(`conversations/${conversation.id}/schedule`, { method: 'PUT', body: { prompt: text, intervalMinutes: interval, language: lang } }))
      onClose()
    } catch (err) { setError(errorMessage(err)) } finally { setSaving(false) }
  }

  const cancel = async () => {
    if (saving) return
    setSaving(true)
    setError(null)
    try {
      onUpdated(await api<Conversation>(`conversations/${conversation.id}/schedule`, { method: 'DELETE' }))
      onClose()
    } catch (err) { setError(errorMessage(err)); setSaving(false) }
  }

  return <div className="co-modal-overlay" role="dialog" aria-modal="true" aria-label={t('Recurring schedule')} onClick={onClose}>
    <div className="co-modal co-schedule-modal" onClick={(event) => event.stopPropagation()}>
      <div className="co-drawer-head">
        <Icon name="refresh" size={22} />
        <div>
          <span className="co-kicker">{t('Recurring schedule')}</span>
          <h2>{t('Run on a timer')}</h2>
          <p>{t('The server sends this prompt for you on a timer, and Ada runs it with her normal tools. Each run appears in the chat, labeled as scheduled.')}</p>
        </div>
        <button className="co-icon-button" aria-label={t('Close')} onClick={onClose}><Icon name="close" /></button>
      </div>
      <form className="co-schedule-body" onSubmit={submit}>
        <label className="co-schedule-field">
          <span>{t('Prompt to run')}</span>
          <textarea ref={field} value={prompt} onChange={(event) => setPrompt(event.target.value)} rows={3} maxLength={4000} placeholder={t('Refresh the list and update the saved file with anything new')} disabled={saving} />
        </label>
        <label className="co-schedule-field">
          <span>{t('How often')}</span>
          <div className="co-schedule-intervals">
            {INTERVALS.map((minutes) => (
              <button key={minutes} type="button" className={interval === minutes ? 'active' : ''} onClick={() => setInterval(minutes)} disabled={saving}>{t(intervalLabel(minutes))}</button>
            ))}
          </div>
        </label>
        <ErrorBanner message={error} />
        <div className="co-schedule-actions">
          {schedule ? <button type="button" className="co-secondary-button" onClick={() => void cancel()} disabled={saving}>{t('Stop schedule')}</button> : null}
          <span className="co-schedule-note">
            {schedule
              ? t('Next run {time}', { time: new Date(schedule.nextRunAt).toLocaleString([], { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' }) })
              : t('The first run fires at the next interval boundary.')}
          </span>
          <button type="submit" className="co-primary-button" disabled={saving || !prompt.trim()}>{schedule ? t('Update schedule') : t('Schedule it')}</button>
        </div>
      </form>
    </div>
  </div>
}
