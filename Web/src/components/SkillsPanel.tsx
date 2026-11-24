import { useEffect, useState } from 'react'
import { api, errorMessage } from '../api/client'
import { useAuth } from '../auth/AuthContext'
import { dateLocale, useI18n } from '../i18n'
import { ErrorBanner } from './ui'

export interface ListedSkill {
  id: string
  name: string
  whenToUse: string
  procedure: string[]
  origin: 'builtIn' | 'migratedTeam' | 'ada'
  enabled: boolean
  updatedAt: string
  /** Everyone's Ada uses it. */
  general: boolean
  /** One of your own skills that also has a copy shared with everyone. */
  sharedCopy: boolean
}

const checks = [
  'No names of people or companies',
  'No emails, phone numbers or addresses',
  'No account numbers, keys or passwords',
  'No customer or order details',
]

/** Skills Ada saved. They are private to you; an admin can share one of their own with everyone after checking it. */
export function SkillsPanel() {
  const { t } = useI18n()
  const { isAdmin } = useAuth()
  const [skills, setSkills] = useState<ListedSkill[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [reviewing, setReviewing] = useState<string | null>(null)
  const [ticked, setTicked] = useState<Set<number>>(new Set())
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    void api<ListedSkill[]>('skills').then(setSkills).catch((err) => setError(errorMessage(err)))
  }, [])

  async function share(id: string, general: boolean) {
    setBusy(true)
    setError(null)
    try {
      setSkills(await api<ListedSkill[]>(`skills/${encodeURIComponent(id)}/share`, { method: 'POST', body: { general } }))
      setReviewing(null)
      setTicked(new Set())
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  const saved = (skills ?? []).filter((skill) => skill.origin !== 'builtIn')
  return <section className="co-setting-card helpers-panel">
    <div className="co-setting-row"><div><b>{t('Saved skills')}</b><p>{t('When you ask Ada to remember how to handle a kind of request, she saves it as a skill. Your skills are only yours: other people’s Ada does not see them. Skills marked shared are used by everyone.')}</p></div></div>
    {skills === null ? null : saved.length ? <ul className="helpers-list">
      {saved.map((skill) => <li key={`${skill.id}-${skill.general ? 'general' : 'own'}`}>
        <details>
          <summary>
            <b>{skill.name}</b>
            <span>{skill.general ? t('Shared with everyone') : skill.sharedCopy ? t('Yours, also shared') : t('Only you')}{skill.enabled ? '' : ` · ${t('Off')}`} · {new Date(skill.updatedAt).toLocaleDateString(dateLocale())}</span>
          </summary>
          <p className="co-panel-note">{skill.whenToUse}</p>
          <ol className="helpers-role">{skill.procedure.map((step, index) => <li key={index}>{step}</li>)}</ol>
          {isAdmin && !skill.general ? reviewing === skill.id ? <div className="skill-share-review">
            <p className="co-panel-note">{t('Everyone’s Ada will use this skill. Check the text above first:')}</p>
            {checks.map((check, index) => <label key={check} className="row">
              <input type="checkbox" checked={ticked.has(index)} onChange={(event) => setTicked((current) => {
                const next = new Set(current)
                if (event.target.checked) next.add(index); else next.delete(index)
                return next
              })} />
              <span>{t(check)}</span>
            </label>)}
            <div className="row">
              <button className="pill" disabled={busy || ticked.size !== checks.length} onClick={() => void share(skill.id, true)}>{skill.sharedCopy ? t('Update the shared copy') : t('Share with everyone')}</button>
              <button className="pill" disabled={busy} onClick={() => { setReviewing(null); setTicked(new Set()) }}>{t('Cancel')}</button>
            </div>
          </div> : <div className="row">
            <button className="pill" onClick={() => { setReviewing(skill.id); setTicked(new Set()) }}>{skill.sharedCopy ? t('Update the shared copy…') : t('Share with everyone…')}</button>
            {skill.sharedCopy ? <button className="pill" disabled={busy} onClick={() => void share(skill.id, false)}>{t('Stop sharing')}</button> : null}
          </div> : null}
          {isAdmin && skill.general ? <div className="row">
            <button className="pill" disabled={busy} onClick={() => void share(skill.id, false)}>{t('Stop sharing')}</button>
          </div> : null}
        </details>
      </li>)}
    </ul> : <p className="co-panel-note">{t('No saved skills yet. Ask Ada to remember how you like a kind of request done.')}</p>}
    <ErrorBanner message={error} />
  </section>
}
