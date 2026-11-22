import { useState } from 'react'
import { api, errorMessage } from '../api/client'
import type { WorkspaceMemory } from '../api/types'
import { useI18n } from '../i18n'
import { Icon } from './coordinator/Icon'
import { ErrorBanner } from './ui'

/** Facts Ada keeps word for word, with add, remove and "forget anything about…". */
export function RememberedPanel({ memory, onChange }: { memory: WorkspaceMemory | null; onChange: (memory: WorkspaceMemory) => void }) {
  const { t } = useI18n()
  const [fact, setFact] = useState('')
  const [about, setAbout] = useState('')
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const pinned = memory?.pinned ?? []

  const run = async (work: () => Promise<void>) => {
    setBusy(true)
    setError(null)
    setNote(null)
    try { await work() } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const add = () => run(async () => {
    onChange(await api<WorkspaceMemory>('workspace/memory/pinned', { method: 'POST', body: { text: fact } }))
    setFact('')
  })
  const remove = (id: string) => run(async () => {
    onChange(await api<WorkspaceMemory>(`workspace/memory/pinned/${id}`, { method: 'DELETE' }))
  })
  const forget = () => run(async () => {
    const view = await api<{ result: { pinnedRemoved: number; summaryLinesRemoved: number; pendingRemoved: number }; memory: WorkspaceMemory }>('workspace/memory/forget', { method: 'POST', body: { about } })
    onChange(view.memory)
    const total = view.result.pinnedRemoved + view.result.summaryLinesRemoved + view.result.pendingRemoved
    setNote(total ? t('Forgot {count} item(s) about “{about}”.', { count: total, about }) : t('Nothing in memory mentions “{about}”.', { about }))
    setAbout('')
  })

  return <section className="co-setting-card remembered">
    <div className="co-setting-row"><div><b>{t('Remembered on request')}</b><p>{t('Facts Ada keeps word for word. Ask her to remember or forget something in any chat, or edit the list here.')}</p></div></div>
    {pinned.length ? <ul className="remembered-list">
      {pinned.map((item) => <li key={item.id}>
        <span>{item.text}</span>
        <button className="co-text-button danger" disabled={busy} aria-label={t('Remove')} title={t('Remove')} onClick={() => void remove(item.id)}><Icon name="close" size={12} /></button>
      </li>)}
    </ul> : <p className="co-panel-note">{t('Nothing yet.')}</p>}
    <form className="remembered-form" onSubmit={(event) => { event.preventDefault(); if (fact.trim()) void add() }}>
      <input type="text" maxLength={500} value={fact} placeholder={t('Something Ada should always know')} aria-label={t('Something Ada should always know')} onChange={(event) => setFact(event.target.value)} />
      <button className="co-secondary-button" disabled={busy || !fact.trim()} type="submit"><Icon name="plus" size={14} />{t('Remember')}</button>
    </form>
    <form className="remembered-form" onSubmit={(event) => { event.preventDefault(); if (about.trim().length >= 3) void forget() }}>
      <input type="text" value={about} placeholder={t('Forget anything about…')} aria-label={t('Forget anything about…')} onChange={(event) => setAbout(event.target.value)} />
      <button className="co-secondary-button" disabled={busy || about.trim().length < 3} type="submit"><Icon name="trash" size={14} />{t('Forget')}</button>
    </form>
    {note ? <p className="co-panel-note">{note}</p> : null}
    <ErrorBanner message={error} />
  </section>
}
