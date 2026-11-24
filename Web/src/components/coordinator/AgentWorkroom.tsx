import { useEffect, useState } from 'react'
import type { Conversation } from '../../api/types'
import { useI18n } from '../../i18n'
import { presentWork, type WorkHelper } from '../../lib/coordinator'
import { Icon } from './Icon'

const stateWords: Record<WorkHelper['state'], string> = {
  working: 'Working',
  done: 'Done',
  failed: 'Had a problem',
  waiting: 'Waiting',
}

/** True on phone-width screens, where the bar stays one line unless the person opens it. */
function isNarrow(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia('(max-width: 760px)').matches
}

/**
 * A slim line above the chat that says, in plain words, who is working on the reply: Ada, and any
 * helpers she brought in (researchAda, judgeAda). It is hidden when nothing is running and the
 * last reply was Ada's alone, so an ordinary chat shows nothing extra.
 */
export function AgentWorkroom({ conversation }: { conversation: Conversation | null }) {
  const { t } = useI18n()
  const work = presentWork(conversation)
  const [open, setOpen] = useState<boolean | null>(null)
  // Each new piece of work starts with the default: details open while helpers work, folded after.
  const latestID = [...(conversation?.messages ?? [])].reverse().find((message) => message.role === 'assistant')?.id
  useEffect(() => setOpen(null), [latestID])
  if (!work.running && work.helpers.length === 0) return null

  // On a phone the open details took a quarter of the screen, so there they stay folded until tapped.
  const expanded = work.helpers.length > 0 && (open ?? (work.running && !isNarrow()))
  const names = work.helpers.map((helper) => helper.name)
  const shown = names.length > 3 ? `${names.slice(0, 3).join(', ')} +${names.length - 3}` : names.join(', ')
  const title = work.running ? t('Ada is working') : t('Last reply')
  const detail = work.running
    ? (work.now ?? t('Working on your message'))
    : t('Ada had help from {names}', { names: shown })

  return <section className={`co-workbar ${work.running ? 'running' : ''}`} aria-label={t('Who is working on this')} aria-live="polite">
    <div className="co-workbar-line">
      <i className={work.running ? 'co-live-dot' : 'co-online-dot'} aria-hidden="true" />
      <b>{title}</b>
      <span className="co-workbar-detail">{detail}</span>
      {work.running && work.helpers.length ? <span className="co-workbar-count">{t('{count} helping', { count: work.helpers.filter((helper) => helper.state === 'working').length || work.helpers.length })}</span> : null}
      {work.helpers.length ? <button type="button" className="co-workbar-toggle" aria-expanded={expanded} onClick={() => setOpen(!expanded)}>{expanded ? t('Hide') : t('Details')}<Icon name="collapse" size={13} /></button> : null}
    </div>
    {expanded ? <div className="co-workbar-details">
      <ul>{work.helpers.map((helper) => <li key={helper.key} className={helper.state}>
        <span className="co-workbar-avatar" aria-hidden="true">{helper.name.trim()[0]?.toUpperCase() ?? '?'}</span>
        <div>
          <p><b>{helper.name}</b><small>{helper.group ? t('Part of {group}', { group: helper.group }) : t('Helper')}</small><em>{t(stateWords[helper.state])}</em></p>
          <span>{helper.summary}</span>
        </div>
      </li>)}</ul>
      <p className="co-workbar-hint">{t('Helpers are short-lived assistants Ada brings in for one part of the job. They only use the tools she gives them, and anything that changes your accounts still asks you first.')}</p>
    </div> : null}
  </section>
}
