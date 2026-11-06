import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import { phaseLabel, type Mission, type MissionStatus, type Team } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { Markdown } from '../components/Markdown'
import { AgentStage, formatCost, formatTokens, StatusChip } from '../components/mission'
import { ErrorBanner, formatDate, Spinner } from '../components/ui'
import { displayText, fileKind, mimeType, saveFile } from '../lib/files'
import { presentMission, type ChatterItem } from '../lib/missionPresentation'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { useLiveMission, type LiveConnection } from '../lib/useLiveMission'
import { makeZip } from '../lib/zip'

type Tab = 'plan' | 'chatter' | 'files' | 'activity'

const REPORT = 'final-report.md'
const ACTIVITY_PAGE = 300

const statusTitle: Record<MissionStatus, string> = {
  queued: '● Queued',
  running: '● Running',
  completed: '✓ Done',
  failed: '✕ Failed',
  stopped: '■ Stopped',
}

/** A short objective for the browser tab. */
export function missionTabTitle(mission: Pick<Mission, 'status' | 'objective'>): string {
  const objective = mission.objective.trim().replace(/\s+/g, ' ')
  const short = objective.length > 48 ? `${objective.slice(0, 47)}…` : objective
  return `${statusTitle[mission.status]} · ${short}`
}

export function MissionPage() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  const { isAdmin } = useAuth()
  const { detail, events, error, connection, running, reload } = useLiveMission(id)
  const [team, setTeam] = useState<Team | undefined>()
  const [tab, setTab] = useState<Tab>('plan')
  const [file, setFile] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const openedReport = useRef(false)

  const mission = detail?.mission
  useDocumentTitle(mission ? missionTabTitle(mission) : null)

  useEffect(() => {
    if (!mission?.teamID) return
    api<Team>(`teams/${mission.teamID}`)
      .then(setTeam)
      .catch(() => setTeam(undefined))
  }, [mission?.teamID])

  const presentation = useMemo(() => presentMission(team, mission, events), [team, mission, events])
  const deliverables = detail?.deliverables ?? []
  const hasReport = deliverables.includes(REPORT)
  const finished = mission ? !running && mission.status !== 'queued' : false

  // A finished mission opens on its final report.
  useEffect(() => {
    openedReport.current = false
  }, [id])
  useEffect(() => {
    if (openedReport.current || !mission || running || !hasReport) return
    openedReport.current = true
    setTab('files')
    setFile(REPORT)
  }, [mission, running, hasReport])

  async function stop() {
    if (!window.confirm('Stop this mission? Agents stop where they are, and it can’t be resumed.')) return
    setActionError(null)
    try {
      await api(`missions/${id}/stop`, { method: 'POST' })
      await reload()
    } catch (err) {
      setActionError(errorMessage(err))
    }
  }

  async function runAgain() {
    if (!mission) return
    setBusy(true)
    setActionError(null)
    try {
      const next = await api<Mission>('missions', { method: 'POST', body: { teamID: mission.teamID, objective: mission.objective } })
      navigate(`/missions/${next.id}`)
    } catch (err) {
      setActionError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  async function remove() {
    if (!window.confirm('Delete this mission and all its files? This can’t be undone.')) return
    try {
      await api(`missions/${id}`, { method: 'DELETE' })
      navigate('/')
    } catch (err) {
      setActionError(errorMessage(err))
    }
  }

  if (!detail) {
    return error ? <ErrorBanner message={error} /> : <div className="center"><Spinner /></div>
  }

  const followUp = mission
    ? `/missions/new?team=${encodeURIComponent(mission.teamID)}&objective=${encodeURIComponent(`Follow-up to “${mission.objective.trim()}”: `)}`
    : '/missions/new'

  return (
    <>
      <div className="page-head">
        <div style={{ minWidth: 0, flex: 1 }}>
          <div className="kicker">
            <Link to="/">Missions</Link> · {mission?.teamName}
          </div>
          <h1 className="mission-title">{mission?.objective}</h1>
          <div className="row" style={{ marginTop: 8 }}>
            {mission ? <StatusChip status={mission.status} /> : null}
            {mission && running ? <span className="chip">{phaseLabel[mission.phase]}</span> : null}
            {running ? <ConnectionChip connection={connection} /> : null}
            <span className="chip">{formatCost(mission?.totalCostUSD ?? 0)}</span>
            <span className="chip">
              {formatTokens(mission?.totalInputTokens ?? 0)} in · {formatTokens(mission?.totalOutputTokens ?? 0)} out
            </span>
            <span className="dim mono" style={{ fontSize: 11 }}>
              {formatDate(mission?.createdAt)}
              {mission?.launchedBy ? ` · by ${mission.launchedBy}` : ''}
            </span>
          </div>
        </div>
        <div className="row">
          {running ? (
            <button className="btn danger" onClick={() => void stop()}>
              Stop
            </button>
          ) : null}
          {finished ? (
            <>
              <Link className="btn ghost" to={followUp}>
                Follow up
              </Link>
              <button className="btn ghost" disabled={busy} onClick={() => void runAgain()}>
                {busy ? 'Launching…' : 'Run again'}
              </button>
            </>
          ) : null}
          {isAdmin && finished ? (
            <button className="btn ghost danger-text" onClick={() => void remove()}>
              Delete
            </button>
          ) : null}
        </div>
      </div>

      <ErrorBanner message={actionError ?? error} />

      <div className="card">
        <AgentStage agents={presentation.agents} compact={finished} />
      </div>

      <div className="tabs" role="tablist">
        {(['plan', 'chatter', 'files', 'activity'] as Tab[]).map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? 'pill active' : 'pill'} onClick={() => setTab(t)}>
            {t}
            {t === 'files' && deliverables.length ? ` (${deliverables.length})` : ''}
          </button>
        ))}
      </div>

      <div className="card">
        {tab === 'plan' ? (
          presentation.tasks.length === 0 ? (
            <p className="muted">{running ? 'The coordinator is planning…' : 'No plan was recorded.'}</p>
          ) : (
            <ol className="task-list">
              {presentation.tasks.map((task) => (
                <li key={`${task.number}-${task.agentName}`} className={`task state-${task.state}`}>
                  <span className="task-num mono">{task.number}</span>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div>{task.goal}</div>
                    <div className="dim mono" style={{ fontSize: 11 }}>
                      {task.agentName}
                      {task.deliverable ? ` → ${task.deliverable}` : ''}
                    </div>
                  </div>
                  <span className={`chip task-${task.state}`}>{task.state}</span>
                </li>
              ))}
            </ol>
          )
        ) : null}

        {tab === 'chatter' ? <Chatter items={presentation.chatter} /> : null}

        {tab === 'files' ? <Files missionID={id} names={deliverables} selected={file} onSelect={setFile} /> : null}

        {tab === 'activity' ? <Activity events={events} /> : null}
      </div>
    </>
  )
}

function ConnectionChip({ connection }: { connection: LiveConnection }) {
  switch (connection) {
    case 'live':
      return <span className="chip em">● Live</span>
    case 'reconnecting':
      return <span className="chip gold">Reconnecting…</span>
    default:
      return <span className="chip">Connecting…</span>
  }
}

/** Team chatter that follows new messages, unless you've scrolled up to read. */
function Chatter({ items }: { items: ChatterItem[] }) {
  const box = useRef<HTMLDivElement>(null)
  const pinned = useRef(true)

  useLayoutEffect(() => {
    const el = box.current
    if (el && pinned.current) el.scrollTop = el.scrollHeight
  }, [items.length])

  if (items.length === 0) return <p className="muted">Nothing said yet.</p>
  return (
    <div
      className="chatter"
      ref={box}
      onScroll={(e) => {
        const el = e.currentTarget
        pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 60
      }}
    >
      {items.map((item) => (
        <div key={item.seq} className={`chat ${item.system ? 'system' : ''} ${item.failed ? 'failed' : ''} role-${item.role ?? 'none'}`}>
          <div className="chat-head mono">
            {item.system ? 'mission' : item.agentName}
            <span className="dim"> · {new Date(item.timestamp).toLocaleTimeString()}</span>
          </div>
          <div className="chat-text">{item.text}</div>
        </div>
      ))}
    </div>
  )
}

/** The raw event log, newest {ACTIVITY_PAGE} first shown, so long missions stay fast. */
function Activity({ events }: { events: { seq: number; kind: string; agentName?: string; text?: string }[] }) {
  const [limit, setLimit] = useState(ACTIVITY_PAGE)
  const shown = events.length > limit ? events.slice(events.length - limit) : events
  const hidden = events.length - shown.length
  return (
    <div className="activity mono">
      {hidden > 0 ? (
        <button className="btn small ghost" style={{ alignSelf: 'center', marginBottom: 6 }} onClick={() => setLimit((l) => l + ACTIVITY_PAGE)}>
          Show {Math.min(hidden, ACTIVITY_PAGE)} earlier events ({hidden} hidden)
        </button>
      ) : null}
      {shown.map((e) => (
        <div key={e.seq} className={`act kind-${e.kind}`}>
          <span className="dim">{String(e.seq).padStart(4, '0')}</span> <span className="act-kind">{e.kind}</span>
          {e.agentName ? <span className="act-agent"> {e.agentName}</span> : null}
          {e.text ? <span className="act-text"> {e.text.length > 400 ? `${e.text.slice(0, 400)}…` : e.text}</span> : null}
        </div>
      ))}
    </div>
  )
}

function Files({ missionID, names, selected, onSelect }: { missionID: string; names: string[]; selected: string | null; onSelect: (name: string) => void }) {
  const [content, setContent] = useState<Record<string, string>>({})
  const [error, setError] = useState<string | null>(null)
  const [zipping, setZipping] = useState(false)
  const current = selected && names.includes(selected) ? selected : (names[0] ?? null)

  const fetchFile = (name: string) => api<string>(`missions/${missionID}/deliverables/${encodeURIComponent(name)}`).then(String)

  useEffect(() => {
    if (!current || content[current] !== undefined) return
    fetchFile(current)
      .then((text) => setContent((c) => ({ ...c, [current]: text })))
      .catch((err) => setError(errorMessage(err)))
  }, [current, missionID, content])

  if (names.length === 0) return <p className="muted">No files yet. Agents write their deliverables here.</p>

  async function downloadAll() {
    setZipping(true)
    setError(null)
    try {
      const files = await Promise.all(names.map(async (name) => ({ name, text: content[name] ?? (await fetchFile(name)) })))
      saveFile(`mission-${missionID.slice(0, 8)}.zip`, makeZip(files), 'application/zip')
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setZipping(false)
    }
  }

  const text = current ? content[current] : undefined

  return (
    <div className="files">
      <div className="file-list">
        {names.map((name) => (
          <button key={name} className={name === current ? 'pill active' : 'pill'} onClick={() => onSelect(name)}>
            {name}
          </button>
        ))}
        {names.length > 1 ? (
          <button className="btn small ghost" style={{ marginTop: 8 }} disabled={zipping} onClick={() => void downloadAll()}>
            {zipping ? 'Zipping…' : 'Download all'}
          </button>
        ) : null}
      </div>
      <div className="file-view">
        <ErrorBanner message={error} />
        {current && text !== undefined ? (
          <>
            <div className="row" style={{ justifyContent: 'flex-end', marginBottom: 8 }}>
              <button className="btn small ghost" onClick={() => void navigator.clipboard.writeText(text)}>
                Copy
              </button>
              <button className="btn small ghost" onClick={() => saveFile(current, text, mimeType(current))}>
                Download
              </button>
            </div>
            {fileKind(current) === 'markdown' ? <Markdown source={text} /> : <pre className="file-text mono">{displayText(current, text)}</pre>}
          </>
        ) : (
          <Spinner />
        )}
      </div>
    </div>
  )
}
