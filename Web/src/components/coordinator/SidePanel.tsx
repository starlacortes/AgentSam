import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react'
import { api, errorMessage } from '../../api/client'
import type { MissionDetail, RunEvent } from '../../api/types'
import { useI18n } from '../../i18n'
import { displayText, fileKind, mimeType, saveFile } from '../../lib/files'
import {
  buildPreviewDocument,
  codePreviewDocument,
  extensionOf,
  FRAME_LOAD_TAG,
  FRAME_READY_TAG,
  FRAME_URL,
  isConsoleMessage,
  isHTML,
  pickEntry,
  PREVIEW_TEXT_EXTENSIONS,
  type PageConsoleMessage,
  type PreviewSource,
} from '../../lib/preview'
import { useLiveMission } from '../../lib/useLiveMission'
import { makeZip } from '../../lib/zip'
import { Markdown } from '../Markdown'
import { ErrorBanner, Spinner } from '../ui'
import { Icon, type IconName } from './Icon'

export type CanvasTab = 'preview' | 'console' | 'files'

export interface CanvasState {
  tab: CanvasTab
  source: PreviewSource | null
  /** Which of the conversation's missions the console and files follow; newest when unset. */
  missionID: string | null
}

type Device = 'desktop' | 'tablet' | 'phone'
type ConsoleFilter = 'all' | 'agents' | 'page' | 'errors'

const deviceWidth: Record<Device, string> = { desktop: '100%', tablet: '768px', phone: '375px' }
const LOGGED_KINDS = new Set<RunEvent['kind']>(['phase', 'taskStarted', 'toolCall', 'taskDone', 'deliverable', 'verifyVerdict', 'notice', 'missionEnd', 'error'])
const MAX_PAGE_LOGS = 500

export interface ConsoleRow {
  id: string
  origin: 'agent' | 'page'
  level: 'info' | 'warn' | 'error' | 'success' | 'log' | 'debug'
  who: string
  text: string
  time: number
}

/** Merges the mission's work log with the preview page's console, oldest first. */
export function consoleRows(events: RunEvent[], page: PageConsoleMessage[]): ConsoleRow[] {
  const agentRows: ConsoleRow[] = events.filter((event) => LOGGED_KINDS.has(event.kind)).map((event) => ({
    id: event.id,
    origin: 'agent',
    level: event.kind === 'error' ? 'error' : event.kind === 'taskDone' || event.kind === 'missionEnd' ? 'success' : event.kind === 'notice' || event.kind === 'verifyVerdict' ? 'warn' : 'info',
    who: event.agentName ?? event.kind,
    text: event.kind === 'deliverable' ? `wrote ${event.deliverableName ?? event.text ?? ''}` : (event.text ?? event.kind),
    time: Date.parse(event.timestamp),
  }))
  const pageRows: ConsoleRow[] = page.map((entry, index) => ({
    id: `page-${entry.time}-${index}`,
    origin: 'page',
    level: entry.level === 'warn' ? 'warn' : entry.level === 'error' ? 'error' : entry.level === 'debug' ? 'debug' : 'log',
    who: 'page',
    text: entry.text,
    time: entry.time,
  }))
  return [...agentRows, ...pageRows].sort((a, b) => a.time - b.time)
}

function LiveMission({ missionID, reloadToken, onData }: { missionID: string; reloadToken: number; onData: (detail: MissionDetail | null, events: RunEvent[]) => void }) {
  const live = useLiveMission(missionID)
  const { reload } = live
  useEffect(() => { onData(live.detail, live.events) }, [live.detail, live.events, onData])
  useEffect(() => { if (reloadToken) void reload() }, [reloadToken, reload])
  return null
}

function fetchDeliverable(missionID: string, name: string): Promise<string> {
  return api<string>(`missions/${missionID}/deliverables/${encodeURIComponent(name)}`).then(String)
}

function Tab({ name, icon, label, active, badge, onSelect }: { name: CanvasTab; icon: IconName; label: string; active: boolean; badge?: number; onSelect: (tab: CanvasTab) => void }) {
  return <button type="button" role="tab" aria-selected={active} className={active ? 'active' : ''} onClick={() => onSelect(name)}>
    <Icon name={icon} size={13} />{label}{badge ? <span className="co-canvas-badge" aria-label={`${badge}`}>{badge > 99 ? '99+' : badge}</span> : null}
  </button>
}

export function SidePanel({ state, missionIDs, onChange, onClose, onResize }: {
  state: CanvasState
  missionIDs: string[]
  onChange: (state: CanvasState) => void
  onClose: () => void
  onResize: (width: number) => void
}) {
  const { t } = useI18n()
  const missionID = state.source?.kind === 'mission' ? state.source.missionID : (state.missionID ?? missionIDs[0] ?? null)
  const [detail, setDetail] = useState<MissionDetail | null>(null)
  const [events, setEvents] = useState<RunEvent[]>([])
  const [reloadToken, setReloadToken] = useState(0)
  const [files, setFiles] = useState<Record<string, string>>({})
  const [loadingFiles, setLoadingFiles] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [device, setDevice] = useState<Device>('desktop')
  const [frameKey, setFrameKey] = useState(0)
  const [pageLogs, setPageLogs] = useState<PageConsoleMessage[]>([])
  const [filter, setFilter] = useState<ConsoleFilter>('all')
  const [seenErrors, setSeenErrors] = useState(0)
  const [selectedFile, setSelectedFile] = useState<string | null>(null)
  const frame = useRef<HTMLIFrameElement>(null)
  const logBox = useRef<HTMLDivElement>(null)
  const pinned = useRef(true)

  const onData = useCallback((next: MissionDetail | null, nextEvents: RunEvent[]) => {
    setDetail(next)
    setEvents(nextEvents)
  }, [])

  useEffect(() => {
    setDetail(null)
    setEvents([])
    setFiles({})
    setSelectedFile(null)
  }, [missionID])

  const deliverables = useMemo(() => (detail?.mission.id === missionID ? detail?.deliverables ?? [] : []), [detail, missionID])
  const deliverableKey = deliverables.join('\n')
  const entry = state.source?.kind === 'mission' && state.source.entry ? state.source.entry : pickEntry(deliverables)
  const pages = deliverables.filter(isHTML)

  // Fetch the files a mission preview needs whenever the file list changes.
  useEffect(() => {
    if (state.source?.kind === 'code' || !missionID || !entry) return
    let active = true
    const names = deliverableKey.split('\n').filter((name) => PREVIEW_TEXT_EXTENSIONS.has(extensionOf(name)))
    setLoadingFiles(true)
    void Promise.all(names.map(async (name) => [name, await fetchDeliverable(missionID, name).catch(() => '')] as const))
      .then((pairs) => { if (active) { setFiles(Object.fromEntries(pairs)); setError(null) } })
      .catch((err) => { if (active) setError(errorMessage(err)) })
      .finally(() => { if (active) setLoadingFiles(false) })
    return () => { active = false }
  }, [missionID, entry, deliverableKey, state.source?.kind, reloadToken])

  const doc = useMemo(() => {
    if (state.source?.kind === 'code') return codePreviewDocument(state.source.language, state.source.code)
    if (entry && files[entry] !== undefined) return buildPreviewDocument(entry, files)
    return null
  }, [state.source, entry, files])

  // The shell can only be written once, so every new document (or reload) gets a fresh frame.
  const docVersion = useRef(0)
  const docKey = useMemo(() => { docVersion.current += 1; return docVersion.current }, [doc])
  const frameID = `${docKey}-${frameKey}`
  useEffect(() => { setPageLogs([]) }, [frameID])
  const docRef = useRef(doc)
  docRef.current = doc

  useEffect(() => {
    const listen = (event: MessageEvent) => {
      if (!frame.current || event.source !== frame.current.contentWindow) return
      if ((event.data as { tag?: string } | null)?.tag === FRAME_READY_TAG) {
        if (docRef.current) frame.current.contentWindow?.postMessage({ tag: FRAME_LOAD_TAG, html: docRef.current }, '*')
        return
      }
      if (!isConsoleMessage(event.data)) return
      const { level, text, time } = event.data
      setPageLogs((current) => [...current, { level, text, time: typeof time === 'number' ? time : Date.now() }].slice(-MAX_PAGE_LOGS))
    }
    window.addEventListener('message', listen)
    return () => window.removeEventListener('message', listen)
  }, [])

  const rows = useMemo(() => consoleRows(events, pageLogs), [events, pageLogs])
  const visibleRows = rows.filter((row) => filter === 'all' || (filter === 'agents' && row.origin === 'agent') || (filter === 'page' && row.origin === 'page') || (filter === 'errors' && row.level === 'error'))
  const errorCount = rows.filter((row) => row.level === 'error').length
  useEffect(() => { if (state.tab === 'console') setSeenErrors(errorCount) }, [state.tab, errorCount])

  useLayoutEffect(() => {
    const box = logBox.current
    if (box && pinned.current) box.scrollTop = box.scrollHeight
  }, [visibleRows.length, state.tab])

  const select = (tab: CanvasTab) => onChange({ ...state, tab })
  const reload = () => { setFrameKey((key) => key + 1); setReloadToken((token) => token + 1) }

  const startResize = (event: ReactPointerEvent<HTMLDivElement>) => {
    event.preventDefault()
    const handle = event.currentTarget
    handle.setPointerCapture(event.pointerId)
    const move = (moveEvent: PointerEvent) => onResize(window.innerWidth - moveEvent.clientX)
    const end = () => { handle.removeEventListener('pointermove', move); handle.removeEventListener('pointerup', end); handle.removeEventListener('pointercancel', end) }
    handle.addEventListener('pointermove', move)
    handle.addEventListener('pointerup', end)
    handle.addEventListener('pointercancel', end)
  }

  const downloadPage = () => {
    if (!doc) return
    const name = state.source?.kind === 'code' ? 'preview.html' : (entry ?? 'index.html').split('/').pop() ?? 'index.html'
    saveFile(name, doc, 'text/html;charset=utf-8')
  }

  const title = state.source?.kind === 'code' ? state.source.title : entry ?? t('Preview')

  return <aside className="co-canvas" aria-label={t('Preview and console')}>
    <div className="co-canvas-resize" role="separator" aria-orientation="vertical" aria-label={t('Resize panel')} onPointerDown={startResize} />
    <header className="co-canvas-head">
      <div className="co-canvas-tabs" role="tablist">
        <Tab name="preview" icon="monitor" label={t('Preview')} active={state.tab === 'preview'} onSelect={select} />
        <Tab name="console" icon="terminal" label={t('Console')} active={state.tab === 'console'} badge={state.tab === 'console' ? 0 : Math.max(0, errorCount - seenErrors)} onSelect={select} />
        <Tab name="files" icon="file" label={t('Files')} active={state.tab === 'files'} badge={deliverables.length || undefined} onSelect={select} />
      </div>
      {missionIDs.length > 1 && state.source?.kind !== 'code' ? <select className="co-canvas-select" aria-label={t('Team run')} value={missionID ?? ''} onChange={(event) => onChange({ ...state, missionID: event.target.value, source: state.source?.kind === 'mission' ? { kind: 'mission', missionID: event.target.value } : state.source })}>
        {missionIDs.map((id, index) => <option key={id} value={id}>{index === 0 ? t('Latest run') : t('Run {n}', { n: missionIDs.length - index })}</option>)}
      </select> : null}
      <button type="button" className="co-icon-button" aria-label={t('Close panel')} onClick={onClose}><Icon name="close" size={15} /></button>
    </header>
    {missionID ? <LiveMission key={missionID} missionID={missionID} reloadToken={reloadToken} onData={onData} /> : null}
    <ErrorBanner message={error} />

    {state.tab === 'preview' ? <div className="co-canvas-body co-preview">
      <div className="co-preview-bar">
        <button type="button" className="co-icon-button" aria-label={t('Reload preview')} title={t('Reload preview')} onClick={reload}><Icon name="refresh" size={14} /></button>
        <span className="co-preview-address" title={title}>{title}</span>
        {pages.length > 1 && state.source?.kind !== 'code' ? <select className="co-canvas-select" aria-label={t('Page')} value={entry ?? ''} onChange={(event) => missionID && onChange({ ...state, source: { kind: 'mission', missionID, entry: event.target.value } })}>{pages.map((name) => <option key={name} value={name}>{name}</option>)}</select> : null}
        <div className="co-device-toggle" role="group" aria-label={t('Preview width')}>
          {(['desktop', 'tablet', 'phone'] as Device[]).map((name) => <button key={name} type="button" aria-pressed={device === name} aria-label={t(name === 'desktop' ? 'Desktop width' : name === 'tablet' ? 'Tablet width' : 'Phone width')} onClick={() => setDevice(name)}><Icon name={name === 'desktop' ? 'monitor' : name} size={13} /></button>)}
        </div>
        <button type="button" className="co-icon-button" aria-label={t('Download page')} title={t('Download page')} disabled={!doc} onClick={downloadPage}><Icon name="download" size={14} /></button>
      </div>
      <div className="co-preview-stage">
        {doc ? <iframe key={frameID} ref={frame} title={t('Site preview')} referrerPolicy="no-referrer" src={FRAME_URL} style={{ width: deviceWidth[device] }} />
          : loadingFiles ? <div className="co-canvas-empty"><Spinner /></div>
          : <div className="co-canvas-empty"><Icon name="monitor" size={26} /><b>{t('Nothing to preview yet')}</b><p>{missionID && detail?.running ? t('The team is still working. The page appears here once an HTML file is written.') : t('Ask Ada for a web page, then press Preview on its HTML block — or have a team build a site.')}</p></div>}
      </div>
      <p className="co-canvas-note"><Icon name="shield" size={11} />{t('Runs in an isolated sandbox with no access to your account.')}</p>
    </div> : null}

    {state.tab === 'console' ? <div className="co-canvas-body co-console">
      <div className="co-console-bar">
        {(['all', 'agents', 'page', 'errors'] as ConsoleFilter[]).map((name) => <button key={name} type="button" aria-pressed={filter === name} onClick={() => setFilter(name)}>{t(name === 'all' ? 'All' : name === 'agents' ? 'Agents' : name === 'page' ? 'Page' : 'Errors')}</button>)}
        <span className="co-console-live">{detail?.running ? <><i className="co-live-dot" />{t('Live')}</> : null}</span>
        <button type="button" className="co-icon-button" aria-label={t('Clear page output')} title={t('Clear page output')} onClick={() => setPageLogs([])}><Icon name="trash" size={13} /></button>
      </div>
      <div className="co-console-log" ref={logBox} role="log" aria-live="polite" onScroll={(event) => { const el = event.currentTarget; pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40 }}>
        {visibleRows.length ? visibleRows.map((row) => <div key={row.id} className={`co-console-row ${row.level} ${row.origin}`}>
          <time>{new Date(row.time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</time>
          <span className="co-console-who">{row.who}</span>
          <span className="co-console-text">{row.text}</span>
        </div>) : <p className="co-console-empty">{missionID || doc ? t('No output yet.') : t('Team work and preview output appear here.')}</p>}
      </div>
    </div> : null}

    {state.tab === 'files' ? <FilesTab missionID={missionID} names={deliverables} selected={selectedFile} onSelect={setSelectedFile} onPreview={(name) => missionID && onChange({ ...state, tab: 'preview', source: { kind: 'mission', missionID, entry: name } })} /> : null}
  </aside>
}

function FilesTab({ missionID, names, selected, onSelect, onPreview }: { missionID: string | null; names: string[]; selected: string | null; onSelect: (name: string | null) => void; onPreview: (name: string) => void }) {
  const { t } = useI18n()
  const [content, setContent] = useState<Record<string, string>>({})
  const [error, setError] = useState<string | null>(null)
  const current = selected && names.includes(selected) ? selected : null

  useEffect(() => { setContent({}) }, [missionID])
  useEffect(() => {
    if (!missionID || !current || content[current] !== undefined) return
    fetchDeliverable(missionID, current).then((text) => setContent((value) => ({ ...value, [current]: text }))).catch((err) => setError(errorMessage(err)))
  }, [missionID, current, content])

  if (!missionID || !names.length) return <div className="co-canvas-body"><div className="co-canvas-empty"><Icon name="file" size={24} /><b>{t('No files yet')}</b><p>{t('Files your teams write show up here.')}</p></div></div>

  const downloadAll = async () => {
    try {
      const files = await Promise.all(names.map(async (name) => ({ name, text: content[name] ?? await fetchDeliverable(missionID, name) })))
      saveFile(`mission-${missionID.slice(0, 8)}.zip`, makeZip(files), 'application/zip')
    } catch (err) { setError(errorMessage(err)) }
  }

  const text = current ? content[current] : undefined
  return <div className="co-canvas-body co-files">
    <ErrorBanner message={error} />
    {current ? <div className="co-file-view">
      <div className="co-file-view-head">
        <button type="button" className="co-text-button" onClick={() => onSelect(null)}>← {t('All files')}</button>
        <b title={current}>{current}</b>
        {isHTML(current) ? <button type="button" className="co-icon-button" aria-label={t('Preview')} title={t('Preview')} onClick={() => onPreview(current)}><Icon name="eye" size={14} /></button> : null}
        <button type="button" className="co-icon-button" aria-label={t('Download')} title={t('Download')} disabled={text === undefined} onClick={() => text !== undefined && saveFile(current.split('/').pop() ?? current, text, mimeType(current))}><Icon name="download" size={14} /></button>
      </div>
      {text === undefined ? <Spinner /> : fileKind(current) === 'markdown' ? <div className="co-file-markdown"><Markdown source={text} /></div> : <pre className="co-file-code">{displayText(current, text)}</pre>}
    </div> : <>
      <ul className="co-file-list">{names.map((name) => <li key={name}>
        <button type="button" onClick={() => onSelect(name)}><Icon name="file" size={13} /><span>{name}</span></button>
        {isHTML(name) ? <button type="button" className="co-icon-button" aria-label={t('Preview {name}', { name })} title={t('Preview')} onClick={() => onPreview(name)}><Icon name="eye" size={13} /></button> : null}
      </li>)}</ul>
      {names.length > 1 ? <button type="button" className="co-secondary-button co-full-button" onClick={() => void downloadAll()}><Icon name="download" size={13} />{t('Download all')}</button> : null}
    </>}
  </div>
}
