import { useEffect, useRef, useState } from 'react'
import { api, errorMessage } from '../../api/client'
import type { ArchiveSettings, Conversation, ConversationSummary } from '../../api/types'
import { useI18n } from '../../i18n'
import { ErrorBanner, Spinner } from '../ui'
import { Icon } from './Icon'
import { useDialogA11y } from './Overlay'

/** The retention choices the server accepts. `null` keeps archived chats forever. */
export const RETENTION_CHOICES: { days: number | null; label: string }[] = [
  { days: 7, label: '7 days' },
  { days: 30, label: '30 days' },
  { days: 90, label: '90 days' },
  { days: 365, label: '1 year' },
  { days: null, label: 'Never delete' },
]

export function retentionLabel(days: number | null | undefined): string {
  return RETENTION_CHOICES.find((choice) => choice.days === (days ?? null))?.label ?? 'Never delete'
}

/** Whole days until an archive is deleted, or null when archives are kept forever. */
export function daysUntilPurge(archivedAt: string, retentionDays: number | null | undefined, now = Date.now()): number | null {
  if (!retentionDays) return null
  const deadline = new Date(archivedAt).getTime() + retentionDays * 86_400_000
  return Math.max(0, Math.ceil((deadline - now) / 86_400_000))
}

function RetentionChoices({ value, disabled, onChoose }: { value: number | null | undefined; disabled?: boolean; onChoose: (days: number | null) => void }) {
  const { t } = useI18n()
  return <div className="co-schedule-intervals co-retention-choices" role="radiogroup" aria-label={t('Keep archived chats for')}>
    {RETENTION_CHOICES.map((choice) => {
      const active = value !== undefined && (value ?? null) === choice.days
      return <button key={choice.label} type="button" role="radio" aria-checked={active} className={active ? 'active' : ''} disabled={disabled} onClick={() => onChoose(choice.days)}>{t(choice.label)}</button>
    })}
  </div>
}

/**
 * Asked once, the first time someone archives a chat: how long archived chats are kept
 * before the server deletes them. Choosing an option saves it and archives the chat.
 */
export function RetentionPrompt({ onChosen, onClose }: { onChosen: (settings: ArchiveSettings) => void; onClose: () => void }) {
  const { t } = useI18n()
  const ref = useRef<HTMLDivElement>(null)
  const [choice, setChoice] = useState<number | null>(30)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useDialogA11y(ref, onClose)

  const save = async () => {
    setSaving(true)
    setError(null)
    try {
      onChosen(await api<ArchiveSettings>('workspace/archive', { method: 'PUT', body: { retentionDays: choice } }))
    } catch (err) { setError(errorMessage(err)); setSaving(false) }
  }

  return <div className="co-modal-overlay" onClick={onClose}>
    <div ref={ref} className="co-modal co-schedule-modal co-archive-modal" role="dialog" aria-modal="true" aria-labelledby="co-retention-title" onClick={(event) => event.stopPropagation()}>
      <div className="co-drawer-head">
        <Icon name="archive" size={22} />
        <div>
          <span className="co-kicker">{t('Archive')}</span>
          <h2 id="co-retention-title">{t('How long should archived chats be kept?')}</h2>
          <p>{t('Archived chats leave the sidebar but stay in Archived chats, where you can open or restore them. After this long they are deleted with their chat files and photos. Project files and missions are never touched.')}</p>
        </div>
        <button className="co-icon-button" aria-label={t('Close')} onClick={onClose}><Icon name="close" /></button>
      </div>
      <div className="co-schedule-body">
        <RetentionChoices value={choice} disabled={saving} onChoose={setChoice} />
        <ErrorBanner message={error} />
        <div className="co-schedule-actions">
          <span className="co-schedule-note">{t('You can change this any time in Archived chats.')}</span>
          <button type="button" className="co-primary-button" disabled={saving} onClick={() => void save()}>{t('Archive chat')}</button>
        </div>
      </div>
    </div>
  </div>
}

/** Lists archived chats with their deletion date, lets the user open or restore each one, and change retention. */
export function ArchivedChats({ settings, onSettings, onOpen, onRestored, onClose }: {
  settings: ArchiveSettings | null
  onSettings: (settings: ArchiveSettings) => void
  onOpen: (id: string) => void
  onRestored: (conversation: Conversation) => void
  onClose: () => void
}) {
  const { t } = useI18n()
  const ref = useRef<HTMLDivElement>(null)
  const [chats, setChats] = useState<ConversationSummary[] | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  useDialogA11y(ref, onClose)

  const load = () => api<ConversationSummary[]>('conversations?archived=1').then(setChats)
  useEffect(() => { load().catch((err) => setError(errorMessage(err))) }, [])

  const restore = async (id: string) => {
    setBusy(id)
    setError(null)
    try {
      onRestored(await api<Conversation>(`conversations/${id}/archive`, { method: 'DELETE' }))
      setChats((current) => current?.filter((chat) => chat.id !== id) ?? null)
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(null) }
  }

  const changeRetention = async (days: number | null) => {
    setBusy('retention')
    setError(null)
    try {
      onSettings(await api<ArchiveSettings>('workspace/archive', { method: 'PUT', body: { retentionDays: days } }))
      // A shorter limit deletes older archives right away; show what is left.
      await load()
    } catch (err) { setError(errorMessage(err)) } finally { setBusy(null) }
  }

  const retention = settings?.configured ? settings.retentionDays ?? null : undefined

  return <div className="co-modal-overlay" onClick={onClose}>
    <div ref={ref} className="co-modal co-schedule-modal co-archive-modal" role="dialog" aria-modal="true" aria-labelledby="co-archived-title" onClick={(event) => event.stopPropagation()}>
      <div className="co-drawer-head">
        <Icon name="archive" size={22} />
        <div>
          <span className="co-kicker">{t('Archive')}</span>
          <h2 id="co-archived-title">{t('Archived chats')}</h2>
          <p>{t('Open a chat to read it, or restore it to the sidebar. Sending a message in an archived chat restores it too.')}</p>
        </div>
        <button className="co-icon-button" aria-label={t('Close')} onClick={onClose}><Icon name="close" /></button>
      </div>
      <div className="co-schedule-body">
        <div className="co-schedule-field">
          <span>{t('Keep archived chats for')}</span>
          <RetentionChoices value={retention} disabled={busy !== null} onChoose={(days) => void changeRetention(days)} />
        </div>
        <ErrorBanner message={error} />
        {chats === null ? <div className="co-loading"><Spinner /></div> : chats.length === 0 ? <p className="co-archive-empty">{t('No archived chats. To archive one, press × beside it in the sidebar, or swipe it left on a phone.')}</p> : <ul className="co-archive-list">
          {chats.map((chat) => {
            const days = chat.archivedAt ? daysUntilPurge(chat.archivedAt, retention) : null
            return <li key={chat.id}>
              <button type="button" className="co-archive-open" onClick={() => onOpen(chat.id)}>
                <b>{chat.title}</b>
                <small>{chat.projectName === 'Personal' ? t('Personal') : chat.projectName} · {days === null ? t('Kept until you delete it') : days === 0 ? t('Deleted today') : days === 1 ? t('Deleted tomorrow') : t('Deleted in {count} days', { count: days })}</small>
              </button>
              <button type="button" className="co-secondary-button" disabled={busy !== null} onClick={() => void restore(chat.id)}><Icon name="retry" size={13} />{t('Restore')}</button>
            </li>
          })}
        </ul>}
      </div>
    </div>
  </div>
}
