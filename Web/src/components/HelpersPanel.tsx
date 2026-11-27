import { useEffect, useState } from 'react'
import { api, errorMessage } from '../api/client'
import { dateLocale, useI18n } from '../i18n'
import { ErrorBanner } from './ui'

export interface SavedHelper {
  id: string
  function: string
  name: string
  role: string
  groups: string[]
  version: number
  reason: string
  updatedAt: string
}

/** Roles Ada saved for her helpers (researchAda, judgeAda…). Read-only: she proposes changes on a card in the chat. */
export function HelpersPanel() {
  const { t } = useI18n()
  const [helpers, setHelpers] = useState<SavedHelper[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    void api<SavedHelper[]>('helpers').then(setHelpers).catch((err) => setError(errorMessage(err)))
  }, [])

  return <section className="co-setting-card helpers-panel">
    <div className="co-setting-row"><div><b>{t('Ada’s specialists')}</b><p>{t('Ada can hand part of a job to a specialist named after what it does, like researchAda or judgeAda. When she learns a better way for one to work, she proposes it on a card in the chat, and it changes only if you approve. To undo a change, ask her in any chat. Roles you approve apply only to your own Ada.')}</p></div></div>
    {helpers === null ? null : helpers.length ? <ul className="helpers-list">
      {helpers.map((helper) => <li key={helper.id}>
        <details>
          <summary>
            <b>{helper.name}</b>
            <span>{t('Version {version}', { version: helper.version })} · {new Date(helper.updatedAt).toLocaleDateString(dateLocale())}</span>
          </summary>
          {helper.reason ? <p className="co-panel-note">{helper.reason}</p> : null}
          <p className="helpers-role">{helper.role}</p>
          <p className="co-panel-note">{t('Tools: {tools}', { tools: helper.groups.join(', ') })}</p>
        </details>
      </li>)}
    </ul> : <p className="co-panel-note">{t('No saved specialist roles yet. Specialists use their ready roles.')}</p>}
    <ErrorBanner message={error} />
  </section>
}
