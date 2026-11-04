import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import { phaseLabel, type Team } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { Markdown } from '../components/Markdown'
import { AgentStage, formatCost, formatTokens, StatusChip } from '../components/mission'
import { ErrorBanner, formatDate, Spinner } from '../components/ui'
import { presentMission } from '../lib/missionPresentation'
import { useLiveMission } from '../lib/useLiveMission'

type Tab = 'plan' | 'chatter' | 'files' | 'activity'

export function MissionPage() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  const { isAdmin } = useAuth()
  const { detail, events, error, connected, running, reload } = useLiveMission(id)
  const [team, setTeam] = useState<Team | undefined>()
  const [tab, setTab] = useState<Tab>('plan')
  const [file, setFile] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)

  const mission = detail?.mission
  useEffect(() => {
    if (!mission?.teamID) return
    api<Team>(`teams/${mission.teamID}`)
      .then(setTeam)
      .catch(() => setTeam(undefined))
  }, [mission?.teamID])

  const presentation = useMemo(() => presentMission(team, mission, events), [team, mission, events])
  const deliverables = detail?.deliverables ?? []
  const hasReport = deliverables.includes('final-report.md')

  async function stop() {
    setActionError(null)
    try {
      await api(`missions/${id}/stop`, { method: 'POST' })
      await reload()
    } catch (err) {
      setActionError(errorMessage(err))
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
            {running ? <span className={connected ? 'chip em' : 'chip'}>{connected ? 'live' : 'polling'}</span> : null}
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
          {isAdmin && !running ? (
            <button className="btn ghost" onClick={() => void remove()}>
              Delete
            </button>
          ) : null}
        </div>
      </div>

      <ErrorBanner message={actionError ?? error} />

      <div className="card">
        <AgentStage agents={presentation.agents} />
        {mission?.status === 'completed' && hasReport ? (
          <div style={{ textAlign: 'center', marginTop: 16 }}>
            <button
              className="btn"
              onClick={() => {
                setTab('files')
                setFile('final-report.md')
              }}
            >
              Mission complete · Read the final report
            </button>
          </div>
        ) : null}
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

        {tab === 'chatter' ? (
          presentation.chatter.length === 0 ? (
            <p className="muted">Nothing said yet.</p>
          ) : (
            <div className="chatter">
              {presentation.chatter.map((item) => (
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
        ) : null}

        {tab === 'files' ? <Files missionID={id} names={deliverables} selected={file} onSelect={setFile} /> : null}

        {tab === 'activity' ? (
          <div className="activity mono">
            {events.map((e) => (
              <div key={e.seq} className={`act kind-${e.kind}`}>
                <span className="dim">{String(e.seq).padStart(4, '0')}</span> <span className="act-kind">{e.kind}</span>
                {e.agentName ? <span className="act-agent"> {e.agentName}</span> : null}
                {e.text ? <span className="act-text"> {e.text.length > 400 ? `${e.text.slice(0, 400)}…` : e.text}</span> : null}
              </div>
            ))}
          </div>
        ) : null}
      </div>
    </>
  )
}

function Files({ missionID, names, selected, onSelect }: { missionID: string; names: string[]; selected: string | null; onSelect: (name: string) => void }) {
  const [content, setContent] = useState<Record<string, string>>({})
  const [error, setError] = useState<string | null>(null)
  const current = selected ?? names[0] ?? null

  useEffect(() => {
    if (!current || content[current] !== undefined) return
    api<string>(`missions/${missionID}/deliverables/${encodeURIComponent(current)}`)
      .then((text) => setContent((c) => ({ ...c, [current]: text })))
      .catch((err) => setError(errorMessage(err)))
  }, [current, missionID, content])

  if (names.length === 0) return <p className="muted">No files yet. Agents write their deliverables here.</p>

  function download() {
    if (!current || content[current] === undefined) return
    const url = URL.createObjectURL(new Blob([content[current]], { type: 'text/markdown' }))
    const a = document.createElement('a')
    a.href = url
    a.download = current
    a.click()
    URL.revokeObjectURL(url)
  }

  return (
    <div className="files">
      <div className="file-list">
        {names.map((name) => (
          <button key={name} className={name === current ? 'pill active' : 'pill'} onClick={() => onSelect(name)}>
            {name}
          </button>
        ))}
      </div>
      <div className="file-view">
        <ErrorBanner message={error} />
        {current && content[current] !== undefined ? (
          <>
            <div className="row" style={{ justifyContent: 'flex-end', marginBottom: 8 }}>
              <button className="btn small ghost" onClick={() => void navigator.clipboard.writeText(content[current] ?? '')}>
                Copy
              </button>
              <button className="btn small ghost" onClick={download}>
                Download
              </button>
            </div>
            <Markdown source={content[current] ?? ''} />
          </>
        ) : (
          <Spinner />
        )}
      </div>
    </div>
  )
}
