import { useEffect, useRef, useState } from 'react'
import type { ConversationMessage, MessageStep } from '../../api/types'
import { useI18n } from '../../i18n'
import { Icon } from './Icon'

/** "8s", "1m 05s". */
export function formatElapsed(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000))
  if (seconds < 60) return `${seconds}s`
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`
}

function useNow(active: boolean): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!active) return
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [active])
  return now
}

function StepList({ steps, now, reveal = false }: { steps: MessageStep[]; now: number; /** Scroll the list into view when it opens, so it is not hidden under the message box. */ reveal?: boolean }) {
  const list = useRef<HTMLOListElement>(null)
  useEffect(() => { if (reveal) list.current?.scrollIntoView?.({ block: 'nearest' }) }, [reveal, steps.length])
  return <ol className="co-steps" ref={list}>{steps.map((step) => {
    const end = step.finishedAt ? Date.parse(step.finishedAt) : now
    return <li key={step.id} className={step.state}>
      <span className="co-step-mark" aria-hidden="true">{step.state === 'working' ? <i /> : <Icon name={step.state === 'failed' ? 'close' : 'check'} size={10} />}</span>
      <span className="co-step-label" title={step.label}>{step.label}</span>
      <span className="co-step-time">{formatElapsed(end - Date.parse(step.startedAt))}</span>
    </li>
  })}</ol>
}

/** Live status for a running reply: an animated orb, the current step, elapsed time, and the steps so far. */
export function ThinkingIndicator({ message }: { message: ConversationMessage }) {
  const { t } = useI18n()
  const now = useNow(true)
  const [open, setOpen] = useState(false)
  const steps = message.steps ?? []
  const current = [...steps].reverse().find((step) => step.state === 'working')?.label
    ?? message.activity.find((item) => item.agentName === 'Ada')?.summary
    ?? t('Thinking')
  const elapsed = formatElapsed(now - Date.parse(message.createdAt))
  return <div className="co-thinking" role="status" aria-live="polite" aria-label={t('Ada is working')}>
    <div className="co-thinking-row">
      <span className="co-thinking-orb" aria-hidden="true"><i /><i /><i /></span>
      <span className="co-thinking-label" key={current} title={current}>{current}…</span>
      <span className="co-thinking-time">{elapsed}</span>
      {steps.length > 1 ? <button type="button" className="co-thinking-toggle" aria-expanded={open} onClick={() => setOpen((value) => !value)}>{open ? t('Hide steps') : t('{count} steps', { count: steps.length })}<Icon name="chevron" size={10} /></button> : null}
    </div>
    {open ? <StepList steps={steps} now={now} reveal /> : null}
  </div>
}

/** After a reply: "Worked for 14s · 3 steps", expandable. */
export function WorkSummary({ message }: { message: ConversationMessage }) {
  const { t } = useI18n()
  const steps = message.steps ?? []
  if (!steps.length || !message.completedAt) return null
  const duration = formatElapsed(Date.parse(message.completedAt) - Date.parse(message.createdAt))
  return <details className="co-work-summary">
    <summary><Icon name="activity" size={11} />{t('Worked for {time}', { time: duration })} · {steps.length === 1 ? t('1 step') : t('{count} steps', { count: steps.length })}</summary>
    <StepList steps={steps} now={Date.parse(message.completedAt)} />
  </details>
}
