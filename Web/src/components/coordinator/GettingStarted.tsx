import { Link } from 'react-router-dom'
import { useI18n } from '../../i18n'
import { Icon } from './Icon'

export interface SetupStep {
  id: 'key' | 'service' | 'alerts'
  done: boolean
  /** Left out when this person cannot do the step themselves (a member cannot add a key). */
  to?: string
}

const copy: Record<SetupStep['id'], { title: string; detail: string }> = {
  key: { title: 'Add a model key', detail: 'Ada needs one to think and answer.' },
  service: { title: 'Connect a service', detail: 'Gmail, Google Ads, GitHub or Cloudflare, so Ada can work with your accounts.' },
  alerts: { title: 'Turn on alerts', detail: 'Get a notification when Ada needs your approval.' },
}

/** The three things worth setting up first, shown on the empty chat until they are done or dismissed. */
export function GettingStarted({ steps, onDismiss }: { steps: SetupStep[]; onDismiss: () => void }) {
  const { t } = useI18n()
  const done = steps.filter((step) => step.done).length
  return <section className="co-setup" aria-label={t('Getting started')}>
    <header><b>{t('Getting started')}</b><span>{t('{done} of {total} done', { done, total: steps.length })}</span><button type="button" className="co-icon-button" aria-label={t('Hide getting started')} title={t('Hide getting started')} onClick={onDismiss}><Icon name="close" size={14} /></button></header>
    <ol>{steps.map((step) => {
      const body = <><span className="co-setup-mark" aria-hidden="true">{step.done ? <Icon name="check" size={12} /> : null}</span><span className="co-setup-text"><b>{t(copy[step.id].title)}</b><small>{step.id === 'key' && !step.to && !step.done ? t('Ask an admin to add one.') : t(copy[step.id].detail)}</small></span>{!step.done && step.to ? <Icon name="chevron" size={14} /> : null}</>
      return <li key={step.id} className={step.done ? 'done' : ''}>{!step.done && step.to ? <Link to={step.to}>{body}</Link> : <div>{body}</div>}{step.done ? <span className="co-setup-sr">{t('Done')}</span> : null}</li>
    })}</ol>
  </section>
}
