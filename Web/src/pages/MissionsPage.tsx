import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import { phaseLabel, type Mission, type MissionStatus } from '../api/types'
import { ErrorBanner, formatDate, Spinner } from '../components/ui'
import { useAuth } from '../auth/AuthContext'
import type { ProviderStatus } from '../api/types'
import { formatCost, StatusChip } from '../components/mission'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { useI18n } from '../i18n'

const FILTERS: (MissionStatus | 'all')[] = ['all', 'running', 'completed', 'failed', 'stopped']

export function MissionsPage() {
  const [missions, setMissions] = useState<Mission[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<(typeof FILTERS)[number]>('all')
  const { isAdmin } = useAuth()
  const { t } = useI18n()
  const [needsKeys, setNeedsKeys] = useState(false)
  const liveCount = missions?.filter((m) => m.status === 'running' || m.status === 'queued').length ?? 0
  useDocumentTitle(liveCount > 0 ? t('● {count} running · Missions', { count: liveCount }) : t('Missions'))

  useEffect(() => {
    if (!isAdmin) return
    api<ProviderStatus[]>('providers')
      .then((list) => setNeedsKeys(!list.some((p) => p.hasKey)))
      .catch(() => setNeedsKeys(false))
  }, [isAdmin])

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
    // Refresh while the tab is visible, and right away when you come back to it.
    const timer = window.setInterval(() => {
      if (document.visibilityState === 'visible') void load()
    }, 10_000)
    const onVisible = () => {
      if (document.visibilityState === 'visible') void load()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
    }
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
          <div className="kicker">{t('Missions')}</div>
          <h1>{t('What your teams are working on')}</h1>
        </div>
        <Link className="btn" to="/missions/new">
          {t('New mission')}
        </Link>
      </div>
      <ErrorBanner message={error} />
      {needsKeys ? (
        <div className="notice row" style={{ marginBottom: 16 }}>
          <span style={{ flex: 1 }}>{t('No provider has an API key yet, so missions can’t run.')}</span>
          <Link className="btn small" to="/welcome">
            {t('Finish setup')}
          </Link>
        </div>
      ) : null}
      <div className="row" style={{ marginBottom: 16 }}>
        <input
          className="input"
          style={{ flex: '1 1 260px' }}
          placeholder={t('Search objectives and teams')}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label={t('Search missions')}
        />
        <div className="row" role="group" aria-label={t('Filter by status')}>
          {FILTERS.map((f) => (
            <button key={f} className={filter === f ? 'pill active' : 'pill'} onClick={() => setFilter(f)}>
              {t(f)}
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
              <p style={{ marginBottom: 14 }}>{t('No missions yet. Give a team its first objective.')}</p>
              <Link className="btn" to="/missions/new">
                {t('Launch a mission')}
              </Link>
            </>
          ) : (
            <p>{t('No missions match.')}</p>
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
                  {m.launchedBy ? <span>{t('by {name}', { name: m.launchedBy })}</span> : null}
                </div>
              </div>
              <div className="mission-row-side">
                <StatusChip status={m.status} />
                <span className="dim mono" style={{ fontSize: 11 }}>
                  {m.status === 'running' ? t(phaseLabel[m.phase]) : formatCost(m.totalCostUSD)}
                </span>
              </div>
            </Link>
          ))}
        </div>
      )}
    </>
  )
}
