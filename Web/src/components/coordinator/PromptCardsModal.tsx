import { useRef, useState, type FormEvent } from 'react'
import { errorMessage } from '../../api/client'
import { useI18n } from '../../i18n'
import { deletePromptCard, savePromptCard, upsertCard, type PromptCard } from '../../lib/promptCards'
import { ErrorBanner } from '../ui'
import { Icon } from './Icon'
import { useDialogA11y } from './Overlay'

/**
 * Your saved prompts. Tap one to put it in the chat, or add, edit and delete them.
 * `draft` opens the form already holding a prompt, as "Save as prompt card" on a message does.
 */
export function PromptCardsModal({ cards, draft, onChange, onUse, onClose }: { cards: PromptCard[]; draft?: string; onChange: (cards: PromptCard[]) => void; onUse: (text: string) => void; onClose: () => void }) {
  const { t } = useI18n()
  const root = useRef<HTMLDivElement>(null)
  const [editing, setEditing] = useState<string | null>(null)
  const [title, setTitle] = useState('')
  const [text, setText] = useState(draft ?? '')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const textField = useRef<HTMLTextAreaElement>(null)
  useDialogA11y(root, onClose)

  const reset = () => { setEditing(null); setTitle(''); setText('') }

  const edit = (card: PromptCard) => {
    setEditing(card.id)
    setTitle(card.title)
    setText(card.text)
    setError(null)
    window.setTimeout(() => textField.current?.focus(), 0)
  }

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (saving || !text.trim()) return
    setSaving(true)
    setError(null)
    try {
      const saved = await savePromptCard({ id: editing ?? undefined, title: title.trim(), text: text.trim() })
      onChange(upsertCard(cards, saved))
      reset()
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setSaving(false)
    }
  }

  const remove = async (card: PromptCard) => {
    if (saving) return
    setSaving(true)
    setError(null)
    try {
      await deletePromptCard(card.id)
      onChange(cards.filter((item) => item.id !== card.id))
      if (editing === card.id) reset()
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setSaving(false)
    }
  }

  return <div className="co-modal-overlay" onClick={onClose}>
    <div className="co-modal co-schedule-modal co-prompt-modal" ref={root} role="dialog" aria-modal="true" aria-labelledby="co-prompt-title" onClick={(event) => event.stopPropagation()}>
      <div className="co-drawer-head">
        <Icon name="spark" size={22} />
        <div>
          <span className="co-kicker">{t('Prompt cards')}</span>
          <h2 id="co-prompt-title">{t('Your saved prompts')}</h2>
          <p>{t('Tap a card to put its prompt in the chat, ready to send or add to. Cards are saved to your account, so they are on every device.')}</p>
        </div>
        <button className="co-icon-button" aria-label={t('Close')} onClick={onClose}><Icon name="close" /></button>
      </div>
      <div className="co-schedule-body">
        {cards.length ? <ul className="co-trigger-list co-prompt-list">
          {cards.map((card) => <li key={card.id} className={editing === card.id ? 'editing' : ''}>
            <button type="button" className="co-prompt-use" onClick={() => onUse(card.text)} aria-label={t('Use prompt card {title}', { title: card.title })}>
              <b>{card.title}</b>
              <span>{card.text}</span>
            </button>
            <div className="co-trigger-actions">
              <button type="button" className="co-icon-button" aria-label={t('Edit prompt card')} title={t('Edit prompt card')} disabled={saving} onClick={() => edit(card)}><Icon name="edit" size={14} /></button>
              <button type="button" className="co-icon-button" aria-label={t('Delete prompt card')} title={t('Delete prompt card')} disabled={saving} onClick={() => void remove(card)}><Icon name="trash" size={14} /></button>
            </div>
          </li>)}
        </ul> : <p className="co-schedule-note">{t('No prompt cards yet. Save a prompt you use often, and it will wait for you on the new chat screen.')}</p>}
      </div>
      <form className="co-schedule-body co-automation-triggers" onSubmit={(event) => void submit(event)}>
        <h3 className="co-automation-heading">{editing ? t('Edit prompt card') : t('New prompt card')}</h3>
        <label className="co-schedule-field">
          <span>{t('Title (optional)')}</span>
          <input className="co-schedule-input" value={title} maxLength={80} onChange={(event) => setTitle(event.target.value)} placeholder={t('Weekly summary')} disabled={saving} />
        </label>
        <label className="co-schedule-field">
          <span>{t('Prompt')}</span>
          <textarea ref={textField} value={text} rows={3} maxLength={4000} onChange={(event) => setText(event.target.value)} placeholder={t('Summarize this week’s jobs and flag anything unpaid.')} disabled={saving} />
        </label>
        <ErrorBanner message={error} />
        <div className="co-schedule-actions">
          {editing ? <button type="button" className="co-secondary-button" onClick={reset} disabled={saving}>{t('Cancel')}</button> : null}
          <span className="co-schedule-note">{t('{count} of 30 cards', { count: String(cards.length) })}</span>
          <button type="submit" className="co-primary-button" disabled={saving || !text.trim() || (!editing && cards.length >= 30)}>{editing ? t('Save changes') : t('Save card')}</button>
        </div>
      </form>
    </div>
  </div>
}
