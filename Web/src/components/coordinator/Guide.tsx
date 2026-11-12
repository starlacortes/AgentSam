import { useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../../auth/AuthContext'
import { useI18n } from '../../i18n'
import { useDialogA11y } from './Overlay'
import { Icon } from './Icon'

export function Guide({ onFinish }: { onFinish: () => Promise<void> }) {
  const { t } = useI18n()
  const { isAdmin } = useAuth()
  const [step, setStep] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const ref = useRef<HTMLDivElement>(null)
  const finish = () => {
    if (busy) return
    setBusy(true)
    setError(null)
    void onFinish().catch(() => setError(t('The guide preference couldn’t be saved. Check your connection and try again.'))).finally(() => setBusy(false))
  }
  useDialogA11y(ref, finish)
  const slides = [
    { title: t('One conversation. One clear answer.'), body: t('Ask Ada anything. For simple questions, Ada answers directly. For bigger projects, Ada chooses the right team and brings back one consolidated response.'), icon: 'chat' as const },
    { title: t('See the work, not the complexity.'), body: t('The activity area shows short summaries of what each specialist is doing. Your chat stays focused on the result, with links to files and detailed work when you want them.'), icon: 'users' as const },
    { title: t('A workspace that grows with you.'), body: t('Describe a team and Ada will propose one for your approval. Connect Gmail in Connections, inspect or pause Workspace memory, and use Voice for a hands-free conversation.'), icon: 'spark' as const },
  ]
  const slide = slides[step] ?? slides[0]!
  return <div className="co-modal-overlay"><div className="co-guide" ref={ref} role="dialog" aria-modal="true" aria-labelledby="co-guide-title"><div className="co-guide-top"><span className="co-brand-mark">A</span><b>{t('A quick guide to AgentSam')}</b><button className="co-icon-button" aria-label={t('Close guide')} disabled={busy} onClick={finish}><Icon name="close" /></button></div><div className="co-guide-content"><div className="co-guide-copy"><span className="co-kicker">{t('Step {number} of 3', { number: step + 1 })}</span><h1 id="co-guide-title">{slide.title}</h1><p>{slide.body}</p>{step === 2 && isAdmin ? <Link className="co-text-link" to="/settings" onClick={() => void finish()}>{t('Set up model providers')} →</Link> : null}</div><div className="co-guide-visual"><div className="co-guide-demo"><span className="co-empty-orb"><Icon name={slide.icon} size={26} /></span>{step === 0 ? <><div className="co-demo-input">{t('Ask Ada for an outcome…')}<Icon name="arrow" size={15} /></div><div className="co-demo-reply"><span className="co-ada-avatar">A</span><p>{t('I’ll answer directly or bring in the right team. You’ll get one clear response here.')}</p></div></> : null}{step === 1 ? <><div className="co-demo-team">{['A', 'S', 'Q', 'J'].map((letter) => <span className="co-tiny-avatar" key={letter}>{letter}</span>)}</div><div className="co-demo-thought"><b>Scout</b><p>{t('Researching the brief')}</p><b>Ada</b><p>{t('Combining the findings into one answer')}</p></div></> : null}{step === 2 ? <div className="co-demo-list"><span><Icon name="check" />{t('You approve new teams')}</span><span><Icon name="plug" />{t('You control connections')}</span><span><Icon name="memory" />{t('You can inspect or pause memory')}</span><span><Icon name="mic" />{t('Voice includes a keyboard fallback')}</span></div> : null}</div></div></div>{error ? <p className="co-guide-error" role="alert">{error}</p> : null}<div className="co-guide-foot"><div className="co-guide-dots">{slides.map((_, index) => <i key={index} className={step === index ? 'active' : ''} />)}</div><button className="co-text-button" disabled={busy} onClick={finish}>{t('Skip guide')}</button><span className="spacer" />{step > 0 ? <button className="co-secondary-button" onClick={() => setStep((value) => value - 1)}>{t('Back')}</button> : null}{step < 2 ? <button className="co-primary-button" onClick={() => setStep((value) => value + 1)}>{t('Next')}</button> : <button className="co-primary-button" disabled={busy} onClick={finish}>{t('Start chatting')}<Icon name="arrow" size={14} /></button>}</div></div></div>
}
