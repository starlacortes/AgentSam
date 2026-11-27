import { useEffect, useRef, useState } from 'react'
import type { ChoiceAnswer, ChoiceCard, ChoiceQuestion, ChoiceReply } from '../../api/types'
import { useI18n } from '../../i18n'
import { Icon } from './Icon'

// Ada's choice cards (ask_choice). Every field is plain text from the server, drawn as React text
// nodes. One question at a time, Back to change an answer, and a review before a multi-question
// card is sent. The answers go back to Ada as the person's next message.

export interface ChoicePick { picked: number[]; other: string; otherOn: boolean }
export type ChoicePicks = Record<string, ChoicePick>

const EMPTY: ChoicePick = { picked: [], other: '', otherOn: false }

function folded(text: string): string {
  return text.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim()
}

/** The questions that show, in order, given the picks so far: a question with showIf waits for one of its answers. */
export function visibleQuestions(card: ChoiceCard, picks: ChoicePicks): ChoiceQuestion[] {
  const shown: ChoiceQuestion[] = []
  for (const question of card.questions) {
    const condition = question.showIf
    if (condition) {
      const earlier = shown.find((item) => item.id === condition.question)
      if (!earlier) continue
      const chosen = new Set((picks[earlier.id]?.picked ?? []).map((index) => folded(earlier.options[index]?.label ?? '')))
      if (!condition.anyOf.some((label) => chosen.has(folded(label)))) continue
    }
    shown.push(question)
  }
  return shown
}

/** True once the question has what it needs: an option, or their own words where it takes them. */
export function isAnswered(question: ChoiceQuestion, pick: ChoicePick | undefined): boolean {
  if (!pick) return false
  return pick.picked.length > 0 || (question.other && pick.otherOn && pick.other.trim().length > 0)
}

/** "Lisbon", "Planning, Rest", or their own words. */
export function pickLabel(question: ChoiceQuestion, pick: ChoicePick | undefined): string {
  if (!pick) return ''
  const parts = question.multiple || !(pick.otherOn && pick.other.trim()) ? pick.picked.map((index) => question.options[index]?.label).filter(Boolean) as string[] : []
  if (question.other && pick.otherOn && pick.other.trim()) parts.push(pick.other.trim())
  return parts.join(', ')
}

/** What is sent for the questions that show. A one-pick question with their own words sends only those. */
export function buildReply(card: ChoiceCard, picks: ChoicePicks): ChoiceReply {
  return {
    cardID: card.id,
    answers: visibleQuestions(card, picks).map((question) => {
      const pick = picks[question.id] ?? EMPTY
      const own = question.other && pick.otherOn && pick.other.trim() ? pick.other.trim() : undefined
      return { question: question.id, picked: own && !question.multiple ? [] : pick.picked, ...(own ? { other: own } : {}) }
    }),
  }
}

/** The answers as one short line, for the folded card: "Lisbon · Old town · Planning". */
export function answerSummary(answer: ChoiceAnswer | undefined): string {
  if (!answer) return ''
  return answer.items.map((item) => [...item.picked, ...(item.other ? [item.other] : [])].join(', ')).filter(Boolean).join(' · ')
}

/** The answers as words, the same lines the server writes, shown in voice mode as what was said. */
export function answerText(card: ChoiceCard, picks: ChoicePicks): string {
  return visibleQuestions(card, picks).map((question) => `${question.question} → ${pickLabel(question, picks[question.id])}`).join('\n')
}

function Option({ label, detail, on, multiple, disabled, onClick }: { label: string; detail?: string; on: boolean; multiple: boolean; disabled: boolean; onClick: () => void }) {
  return <button type="button" className={`co-choice-option${on ? ' on' : ''}`} role={multiple ? 'checkbox' : 'radio'} aria-checked={on} disabled={disabled} onClick={onClick}>
    <span className={`co-choice-mark ${multiple ? 'box' : 'dot'}`} aria-hidden="true">{on ? (multiple ? <Icon name="check" size={12} /> : <i />) : null}</span>
    <span className="co-choice-text"><b>{label}</b>{detail ? <small>{detail}</small> : null}</span>
  </button>
}

/** The folded card once answered: one line with the answers, open to see the questions. */
function AnsweredChoice({ card }: { card: ChoiceCard }) {
  const { t } = useI18n()
  const [open, setOpen] = useState(false)
  const summary = answerSummary(card.answer)
  const chip = card.state === 'answered' && !card.answer?.inWords ? t('Answered') : t('Answered in your message')
  const heading = card.title ?? card.questions[0]?.question ?? t('Choices')
  return <section className={`co-choice answered${open ? ' open' : ''}`} aria-label={t('Choice card')}>
    <button type="button" className="co-choice-summary" aria-expanded={open} onClick={() => setOpen(!open)}>
      <Icon name="check" size={14} /><b>{heading}</b>{summary ? <span className="co-choice-summary-value">{summary}</span> : null}<span className="co-chip">{chip}</span><Icon name="chevron" size={13} />
    </button>
    {open ? <ol className="co-choice-recap">{card.questions.map((question) => {
      const item = card.answer?.items.find((entry) => entry.questionID === question.id)
      return <li key={question.id}><span>{question.question}</span><b>{item ? [...item.picked, ...(item.other ? [item.other] : [])].join(', ') : '–'}</b></li>
    })}</ol> : null}
  </section>
}

/** A card of choices. Pending and `active` (the latest reply, nothing running): it takes answers. */
export function ChoiceCardView({ card, active, busy = false, onAnswer }: { card: ChoiceCard; active: boolean; busy?: boolean; onAnswer?: (reply: ChoiceReply, text: string) => void }) {
  const { t } = useI18n()
  const [picks, setPicks] = useState<ChoicePicks>({})
  const [step, setStep] = useState(0)
  const [reviewing, setReviewing] = useState(false)
  const [sent, setSent] = useState(false)
  const otherBox = useRef<HTMLInputElement>(null)
  const advance = useRef<number | null>(null)
  useEffect(() => () => { if (advance.current) window.clearTimeout(advance.current) }, [])
  if (card.state !== 'pending' || !active) return card.state === 'pending' ? <ClosedChoice card={card} /> : <AnsweredChoice card={card} />

  const shown = visibleQuestions(card, picks)
  const index = Math.min(step, shown.length - 1)
  const question = shown[index]
  if (!question) return null
  const pick = picks[question.id] ?? EMPTY
  const several = shown.length > 1 || card.questions.length > 1
  const disabled = busy || sent || !onAnswer
  const last = index === shown.length - 1

  const send = (next: ChoicePicks) => {
    if (!onAnswer || disabled) return
    setSent(true)
    onAnswer(buildReply(card, next), answerText(card, next))
  }
  /** After a one-pick tap: the next question, the review, or (a one-question card) send at once. */
  const moveOn = (next: ChoicePicks) => {
    const nowShown = visibleQuestions(card, next)
    const at = nowShown.findIndex((item) => item.id === question.id)
    if (!several) { send(next); return }
    if (advance.current) window.clearTimeout(advance.current)
    // A short pause, so the tap is seen before the card moves on.
    advance.current = window.setTimeout(() => {
      if (at < nowShown.length - 1) setStep(at + 1)
      else setReviewing(true)
    }, 220)
  }
  const choose = (option: number) => {
    const current = picks[question.id] ?? EMPTY
    let picked: number[]
    let otherOn = current.otherOn
    if (question.multiple) picked = current.picked.includes(option) ? current.picked.filter((item) => item !== option) : [...current.picked, option].sort((a, b) => a - b)
    else { picked = [option]; otherOn = false }
    const next = { ...picks, [question.id]: { ...current, picked, otherOn } }
    setPicks(next)
    if (!question.multiple) moveOn(next)
  }
  const toggleOther = () => {
    const current = picks[question.id] ?? EMPTY
    const otherOn = !current.otherOn
    setPicks({ ...picks, [question.id]: { ...current, otherOn, picked: question.multiple || !otherOn ? current.picked : [] } })
    if (otherOn) window.setTimeout(() => otherBox.current?.focus(), 0)
  }
  const next = () => {
    if (!isAnswered(question, pick)) return
    if (!several) { send(picks); return }
    if (last) setReviewing(true)
    else setStep(index + 1)
  }
  const back = () => {
    if (reviewing) { setReviewing(false); setStep(shown.length - 1); return }
    setStep(Math.max(0, index - 1))
  }
  const heading = card.title ?? t('Ada asks')

  return <section className="co-choice" aria-label={t('Choice card')}>
    <div className="co-choice-head">
      <span className="co-choice-icon" aria-hidden="true"><Icon name="spark" size={13} /></span>
      <b>{heading}</b>
      {several ? <span className="co-choice-progress">{reviewing ? t('Review') : t('{n} of {total}', { n: String(index + 1), total: String(shown.length) })}</span> : null}
    </div>
    {several ? <div className="co-choice-steps" aria-hidden="true">{shown.map((item, i) => <i key={item.id} className={reviewing || i < index ? 'done' : i === index ? 'now' : ''} />)}</div> : null}
    {reviewing ? <>
      <p className="co-choice-question">{t('Check your answers')}</p>
      <ol className="co-choice-review">{shown.map((item, i) => <li key={item.id}>
        <div><span>{item.question}</span><b>{pickLabel(item, picks[item.id])}</b></div>
        <button type="button" className="co-text-button" disabled={disabled} onClick={() => { setReviewing(false); setStep(i) }}>{t('Change')}</button>
      </li>)}</ol>
      <div className="co-choice-actions">
        <button type="button" className="co-secondary-button" disabled={disabled} onClick={back}>{t('Back')}</button>
        <button type="button" className="co-primary-button" disabled={disabled} onClick={() => send(picks)}><Icon name="check" size={14} />{sent ? t('Sending…') : t('Send answers')}</button>
      </div>
    </> : <>
      <p className="co-choice-question" id={`choice-${card.id}-${question.id}`}>{question.question}</p>
      {question.multiple ? <p className="co-choice-hint">{t('Pick any that apply')}</p> : null}
      <div className="co-choice-options" role={question.multiple ? 'group' : 'radiogroup'} aria-labelledby={`choice-${card.id}-${question.id}`}>
        {question.options.map((option, i) => <Option key={option.label} label={option.label} detail={option.detail} multiple={question.multiple} on={pick.picked.includes(i) && !(pick.otherOn && !question.multiple)} disabled={disabled} onClick={() => choose(i)} />)}
        {question.other ? <Option label={t('Something else')} multiple={question.multiple} on={pick.otherOn} disabled={disabled} onClick={toggleOther} /> : null}
      </div>
      {question.other && pick.otherOn ? <input ref={otherBox} className="co-choice-other" value={pick.other} maxLength={300} disabled={disabled} placeholder={t('Type your answer')} aria-label={t('Your own answer')}
        onChange={(event) => setPicks({ ...picks, [question.id]: { ...pick, other: event.target.value } })}
        onKeyDown={(event) => { if (event.key === 'Enter' && !event.nativeEvent.isComposing) { event.preventDefault(); next() } }} /> : null}
      {several || question.multiple || question.other ? <div className="co-choice-actions">
        {index > 0 ? <button type="button" className="co-secondary-button" disabled={disabled} onClick={back}>{t('Back')}</button> : null}
        <button type="button" className="co-primary-button" disabled={disabled || !isAnswered(question, pick)} onClick={next}>{!several ? (sent ? t('Sending…') : t('Send')) : last ? t('Review') : t('Next')}</button>
      </div> : null}
    </>}
    {!disabled ? <p className="co-choice-foot">{t('Or just reply in your own words.')}</p> : null}
  </section>
}

/** A card the person moved past without answering on it. */
function ClosedChoice({ card }: { card: ChoiceCard }) {
  const { t } = useI18n()
  return <section className="co-choice answered" aria-label={t('Choice card')}>
    <div className="co-choice-summary static"><Icon name="info" size={14} /><b>{card.title ?? card.questions[0]?.question ?? t('Choices')}</b><span className="co-chip">{t('No longer open')}</span></div>
  </section>
}

/** The person's answers, in place of their message text. */
export function ChoiceReplyCard({ answer }: { answer: ChoiceAnswer }) {
  const { t } = useI18n()
  return <div className="co-choice-reply" aria-label={t('Your answers')}>
    <span className="co-choice-reply-head"><Icon name="check" size={12} />{t('Your answers')}</span>
    <ol>{answer.items.map((item) => <li key={item.questionID}><span>{item.question}</span><b>{[...item.picked, ...(item.other ? [item.other] : [])].join(', ')}</b></li>)}</ol>
  </div>
}
