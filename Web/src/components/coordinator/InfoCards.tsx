import { useEffect, useRef, useState } from 'react'
import type { InfoCard, InfoCardItem } from '../../api/types'
import { dateLocale, useI18n } from '../../i18n'
import { Icon, type IconName } from './Icon'

// Ada's in-chat cards. Every field is plain text from the server, rendered as React text
// nodes, so nothing a model writes can become markup. Unknown templates are skipped.

export const CARD_TEMPLATES = ['stats', 'comparison', 'ranking', 'chart', 'steps', 'timeline', 'summary', 'callout'] as const

function formatNumber(value: number, compact = false): string {
  try {
    return new Intl.NumberFormat(dateLocale(), compact ? { notation: 'compact', maximumFractionDigits: 1 } : { maximumFractionDigits: 2 }).format(value)
  } catch {
    return String(value)
  }
}

/** A number with its unit: "$" and "€" lead, anything else follows ("12 visits", "40%"). */
export function withUnit(value: string, unit?: string): string {
  if (!unit) return value
  if (unit === '$' || unit === '€' || unit === '£') return `${unit}${value}`
  if (unit === '%') return `${value}%`
  return `${value} ${unit}`
}

/** Rounded steps for a chart axis covering [min, max]. */
export function niceTicks(min: number, max: number, count = 3): number[] {
  if (min === max) { max = min + 1 }
  const raw = (max - min) / count
  const power = 10 ** Math.floor(Math.log10(raw))
  const step = [1, 2, 2.5, 5, 10].map((m) => m * power).find((s) => s >= raw) ?? raw
  const start = Math.floor(min / step) * step
  const ticks: number[] = []
  for (let v = start; v <= max + step * 0.001; v += step) ticks.push(Number(v.toFixed(10)))
  const last = ticks[ticks.length - 1] ?? start
  if (last < max) ticks.push(Number((last + step).toFixed(10)))
  return ticks
}

function useWidth<T extends HTMLElement>(fallback: number): [React.RefObject<T | null>, number] {
  const ref = useRef<T>(null)
  const [width, setWidth] = useState(fallback)
  useEffect(() => {
    const element = ref.current
    if (!element) return
    const measure = () => { if (element.clientWidth > 0) setWidth(element.clientWidth) }
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  return [ref, width]
}

/** The arrow follows the sign of the change; its colour follows whether that is good. */
export function trendArrow(detail: string): string {
  const text = detail.trim()
  if (/^[-−–]/.test(text)) return '▼ '
  if (text.startsWith('+')) return '▲ '
  return ''
}

function Stats({ items }: { items: InfoCardItem[] }) {
  return <div className={`co-card-stats count-${Math.min(items.length, 4)}`}>{items.map((item, i) => <div key={i} className="co-card-stat">
    <span className="co-card-stat-label">{item.label}</span>
    <b className="co-card-stat-value">{item.value}</b>
    {item.detail ? <span className={`co-card-stat-detail ${item.tone ?? 'neutral'}`}>{trendArrow(item.detail)}{item.detail}</span> : null}
  </div>)}</div>
}

function Comparison({ card }: { card: InfoCard }) {
  const { t } = useI18n()
  const best = card.highlight
  return <div className="co-card-scroll"><table className="co-card-table">
    <thead><tr><th scope="col"><span className="co-card-sr">{t('Compared')}</span></th>{card.columns.map((column, i) => <th key={i} scope="col" className={i === best ? 'best' : undefined}>{column}{i === best ? <span className="co-card-best">{t('Recommended')}</span> : null}</th>)}</tr></thead>
    <tbody>{card.rows.map((row, r) => <tr key={r}><th scope="row">{row.label}</th>{row.values.map((value, i) => <td key={i} className={i === best ? 'best' : undefined}>{value}</td>)}</tr>)}</tbody>
  </table></div>
}

function Ranking({ card }: { card: InfoCard }) {
  const numbers = card.items.map((item) => item.number).filter((n): n is number => typeof n === 'number')
  const bars = numbers.length === card.items.length && numbers.length > 0
  const top = bars ? Math.max(...numbers.map(Math.abs), 0) : 0
  return <ol className="co-card-ranking">{card.items.map((item, i) => <li key={i}>
    <span className="co-card-rank">{i + 1}</span>
    <div className="co-card-rank-body">
      <div className="co-card-rank-line"><span className="co-card-rank-label">{item.label}</span>{item.value || bars ? <b>{item.value ?? withUnit(formatNumber(item.number ?? 0), card.unit)}</b> : null}</div>
      {bars ? <span className="co-card-rank-bar" aria-hidden="true"><i style={{ width: `${top ? Math.max(2, (Math.abs(item.number ?? 0) / top) * 100) : 0}%` }} /></span> : null}
      {item.detail ? <span className="co-card-rank-detail">{item.detail}</span> : null}
    </div>
  </li>)}</ol>
}

function Chart({ card }: { card: InfoCard }) {
  const { t } = useI18n()
  const [box, width] = useWidth<HTMLDivElement>(320)
  const [active, setActive] = useState<number | null>(null)
  const points = card.items.filter((item) => typeof item.number === 'number')
  const values: number[] = points.map((item) => item.number ?? 0)
  const at = (i: number) => values[i] ?? 0
  const line = card.chart === 'line'
  const low = Math.min(...values)
  const high = Math.max(...values)
  // Bars start at zero so their lengths are honest; a line may zoom in on its range.
  const ticks = line ? niceTicks(low === high ? low - 1 : low, high) : niceTicks(Math.min(0, low), Math.max(0, high))
  const min = ticks[0] ?? 0
  const max = ticks[ticks.length - 1] ?? 1
  const height = 168
  const left = 40
  const right = 8
  const top = 10
  const bottom = 26
  const plotW = Math.max(60, width - left - right)
  const plotH = height - top - bottom
  const step = plotW / points.length
  const y = (v: number) => top + plotH - ((v - min) / (max - min || 1)) * plotH
  const x = (i: number) => left + step * i + step / 2
  // Label every point when there is room, otherwise every few, always keeping the last one.
  const every = Math.max(1, Math.ceil(points.length / Math.max(1, Math.floor(plotW / 46))))
  const showLabel = (i: number) => i % every === 0 || i === points.length - 1
  // Until a point is picked: the latest for a trend, the largest for categories.
  const shown = active ?? (line ? points.length - 1 : values.indexOf(high))
  const barW = Math.max(3, Math.min(36, step - 2))
  const zero = y(Math.max(min, Math.min(0, max)))
  const shape = points.map((_, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(at(i)).toFixed(1)}`).join(' ')
  return <div className="co-card-chart" ref={box}>
    <p className="co-card-readout" aria-live="polite"><span>{points[shown]?.label}</span><b>{withUnit(formatNumber(at(shown)), card.unit)}</b></p>
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} role="img" aria-label={card.title ?? t('Chart')} onPointerLeave={() => setActive(null)}>
      {ticks.map((tick) => <g key={tick} className="co-card-grid">
        <line x1={left} x2={width - right} y1={y(tick)} y2={y(tick)} />
        <text x={left - 6} y={y(tick)} dy="0.32em" textAnchor="end">{formatNumber(tick, true)}</text>
      </g>)}
      {line
        ? <path className="co-card-line" d={shape} />
        : points.map((_, i) => {
          const v = at(i)
          const yTop = Math.min(y(v), zero)
          const h = Math.max(1, Math.abs(zero - y(v)))
          const r = Math.min(4, barW / 2, h)
          // Rounded at the data end, square on the baseline.
          const d = v >= 0
            ? `M${x(i) - barW / 2},${zero} V${yTop + r} Q${x(i) - barW / 2},${yTop} ${x(i) - barW / 2 + r},${yTop} H${x(i) + barW / 2 - r} Q${x(i) + barW / 2},${yTop} ${x(i) + barW / 2},${yTop + r} V${zero} Z`
            : `M${x(i) - barW / 2},${zero} V${zero + h - r} Q${x(i) - barW / 2},${zero + h} ${x(i) - barW / 2 + r},${zero + h} H${x(i) + barW / 2 - r} Q${x(i) + barW / 2},${zero + h} ${x(i) + barW / 2},${zero + h - r} V${zero} Z`
          return <path key={i} className={`co-card-bar ${i === shown ? 'on' : ''}`} d={d} />
        })}
      {line ? points.map((_, i) => <circle key={i} className={`co-card-dot ${i === shown ? 'on' : ''}`} cx={x(i)} cy={y(at(i))} r={i === shown ? 4.5 : points.length > 12 ? 0 : 3} />) : null}
      {points.map((point, i) => showLabel(i) ? <text key={i} className="co-card-xlabel" x={x(i)} y={height - 8} textAnchor="middle">{point.label.length > 8 ? point.label.slice(0, 7) + '…' : point.label}</text> : null)}
      {points.map((point, i) => <rect key={i} className="co-card-hit" x={left + step * i} y={top} width={step} height={plotH + bottom} tabIndex={0} aria-label={`${point.label}: ${withUnit(formatNumber(at(i)), card.unit)}`} onPointerEnter={() => setActive(i)} onPointerDown={() => setActive(i)} onFocus={() => setActive(i)} />)}
    </svg>
    <table className="co-card-sr"><tbody>{points.map((point, i) => <tr key={i}><th>{point.label}</th><td>{withUnit(formatNumber(at(i)), card.unit)}</td></tr>)}</tbody></table>
  </div>
}

const STEP_ICON: Record<string, IconName | null> = { done: 'check', failed: 'close', current: null, todo: null }

function Steps({ items }: { items: InfoCardItem[] }) {
  const { t } = useI18n()
  const label: Record<string, string> = { done: t('Done'), current: t('In progress'), todo: t('To do'), failed: t('Failed') }
  return <ol className="co-card-steps">{items.map((item, i) => {
    const state = item.state ?? 'todo'
    const icon = STEP_ICON[state]
    return <li key={i} className={state}>
      <span className="co-card-step-mark" aria-hidden="true">{icon ? <Icon name={icon} size={12} /> : state === 'current' ? <i /> : i + 1}</span>
      <div><span className="co-card-step-label">{item.label}</span>{state === 'current' || state === 'failed' ? <span className={`co-card-step-state ${state}`}>{label[state]}</span> : <span className="co-card-sr">{label[state]}</span>}
        {item.detail ? <span className="co-card-step-detail">{item.detail}</span> : null}</div>
    </li>
  })}</ol>
}

function Timeline({ items }: { items: InfoCardItem[] }) {
  return <ol className="co-card-timeline">{items.map((item, i) => <li key={i}>
    <span className="co-card-when">{item.when}</span>
    <div><span className="co-card-step-label">{item.label}</span>{item.detail ? <span className="co-card-step-detail">{item.detail}</span> : null}</div>
  </li>)}</ol>
}

function Summary({ items }: { items: InfoCardItem[] }) {
  return <dl className="co-card-summary">{items.map((item, i) => <div key={i}><dt>{item.label}</dt><dd>{item.value}{item.detail ? <span>{item.detail}</span> : null}</dd></div>)}</dl>
}

const CALLOUT_ICON: Record<string, IconName> = { info: 'info', success: 'check', warning: 'shield', danger: 'shield' }

function Callout({ card }: { card: InfoCard }) {
  const { t } = useI18n()
  const tone = card.tone ?? 'info'
  const fallback: Record<string, string> = { info: t('Note'), success: t('Done'), warning: t('Heads up'), danger: t('Important') }
  return <div className={`co-card-callout ${tone}`} role={tone === 'danger' || tone === 'warning' ? 'alert' : undefined}>
    <span className="co-card-callout-icon" aria-hidden="true"><Icon name={CALLOUT_ICON[tone] ?? 'info'} size={15} /></span>
    <div><b>{card.title ?? fallback[tone]}</b><p>{card.text}</p>{card.note ? <span className="co-card-note">{card.note}</span> : null}</div>
  </div>
}

export function InfoCardView({ card }: { card: InfoCard }) {
  const { t } = useI18n()
  if (!(CARD_TEMPLATES as readonly string[]).includes(card.template)) return null
  if (card.template === 'callout') return <section className="co-card callout-card" aria-label={card.title ?? t('Card')}><Callout card={card} /></section>
  let body: React.ReactNode
  switch (card.template) {
    case 'stats': body = <Stats items={card.items} />; break
    case 'comparison': body = <Comparison card={card} />; break
    case 'ranking': body = <Ranking card={card} />; break
    case 'chart': body = <Chart card={card} />; break
    case 'steps': body = <Steps items={card.items} />; break
    case 'timeline': body = <Timeline items={card.items} />; break
    default: body = <Summary items={card.items} />
  }
  return <section className={`co-card ${card.template}-card`} aria-label={card.title ?? t('Card')}>
    {card.title ? <h3 className="co-card-title">{card.title}</h3> : null}
    {body}
    {card.note ? <p className="co-card-note">{card.note}</p> : null}
  </section>
}

export function InfoCards({ cards }: { cards?: InfoCard[] }) {
  if (!cards?.length) return null
  return <div className="co-cards">{cards.map((card) => <InfoCardView key={card.id} card={card} />)}</div>
}
