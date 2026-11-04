import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import { phaseLabel, type Mission, type MissionStatus } from '../api/types'
import { ErrorBanner, formatDate, Spinner } from '../components/ui'
import { formatCost, StatusChip } from '../components/mission'

const FILTERS: (MissionStatus | 'all')[] = ['all', 'running', 'completed', 'failed', 'stopped']

export function MissionsPage() {
  const [missions, setMissions] = useState<Mission[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<(typeof FILTERS)[number]>('all')

  const load = useCallback(async () => {
    try {
      setMissions(await api<Mission[]>('missions?limit=200'))
      setError(null)
    } catch (err) {
      setError(errorMessage(err))
    }
  }, [])

  useEffect(() => {
    void load()
    const timer = window.setInterval(() => void load(), 10_000)
    return () => window.clearInterval(timer)
  }, [load])

  const shown = useMemo(() => {
    if (!missions) return []
    const q = query.trim().toLowerCase()
    return missions
      .filter((m) => filter === 'all' || m.status === filter || (filter === 'running' && m.status === 'queued'))
      .filter((m) => !q || m.objective.toLowerCase().includes(q) || m.teamName.toLowerCase().includes(q))
      .sort((a, b) => {
        const live = (m: Mission) => (m.status === 'running' || m.status === 'queued' ? 1 : 0)
        return live(b) - live(a) || b.createdAt.localeCompare(a.createdAt)
      })
  }, [missions, query, filter])

  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">Missions</div>
          <h1>What your teams are working on</h1>
        </div>
        <Link className="btn" to="/missions/new">
          New mission
        </Link>
      </div>
      <ErrorBanner message={error} />
      <div className="row" style={{ marginBottom: 16 }}>
        <input
          className="input"
          style={{ flex: '1 1 260px' }}
          placeholder="Search objectives and teams"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search missions"
        />
        <div className="row" role="group" aria-label="Filter by status">
          {FILTERS.map((f) => (
            <button key={f} className={filter === f ? 'pill active' : 'pill'} onClick={() => setFilter(f)}>
              {f}
            </button>
          ))}
        </div>
      </div>
      {!missions ? (
        <div className="center">
          <Spinner />
        </div>
      ) : shown.length === 0 ? (
        <div className="card empty">
          {missions.length === 0 ? (
            <>
              <p style={{ marginBottom: 14 }}>No missions yet. Give a team its first objective.</p>
              <Link className="btn" to="/missions/new">
                Launch a mission
              </Link>
            </>
          ) : (
            <p>No missions match.</p>
          )}
        </div>
      ) : (
        <div className="mission-list">
          {shown.map((m) => (
            <Link key={m.id} to={`/missions/${m.id}`} className="mission-row card">
              <div className="mission-row-main">
                <div className="mission-objective">{m.objective}</div>
                <div className="row dim mono" style={{ fontSize: 11.5, gap: 12 }}>
                  <span>{m.teamName}</span>
                  <span>{formatDate(m.createdAt)}</span>
                  {m.launchedBy ? <span>by {m.launchedBy}</span> : null}
                </div>
              </div>
              <div className="mission-row-side">
                <StatusChip status={m.status} />
                <span className="dim mono" style={{ fontSize: 11 }}>
                  {m.status === 'running' ? phaseLabel[m.phase] : formatCost(m.totalCostUSD)}
                </span>
              </div>
            </Link>
          ))}
        </div>
      )}
    </>
  )
}
