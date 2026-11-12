import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { Team } from '../api/types'
import { Avatar } from '../components/mission'
import { ErrorBanner, Spinner } from '../components/ui'
import { useI18n } from '../i18n'

export function TeamsPage() {
  const { t } = useI18n()
  useDocumentTitle(t('Teams'))
  const [teams, setTeams] = useState<Team[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    api<Team[]>('teams')
      .then((list) => setTeams([...list].sort((a, b) => a.name.localeCompare(b.name))))
      .catch((err) => setError(errorMessage(err)))
  }, [])

  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">{t('Teams')}</div>
          <h1>{t('Your agent teams')}</h1>
        </div>
        <div className="row">
          <Link className="btn ghost" to="/templates">
            {t('Browse templates')}
          </Link>
          <Link className="btn" to="/teams/new">
            {t('New team')}
          </Link>
        </div>
      </div>
      <ErrorBanner message={error} />
      {!teams ? (
        <Spinner />
      ) : teams.length === 0 ? (
        <div className="card empty">
          <p style={{ marginBottom: 14 }}>{t('No teams yet.')}</p>
          <Link className="btn" to="/templates">
            {t('Hire one from a template')}
          </Link>
        </div>
      ) : (
        <div className="team-picker">
          {teams.map((team) => (
            <Link key={team.id} to={`/teams/${team.id}`} className="pick-card" style={{ color: 'inherit', textDecoration: 'none' }}>
              <div className="avatar-stack">
                {team.agents.slice(0, 6).map((a) => (
                  <Avatar key={a.id} name={a.name} role={a.role} size={34} />
                ))}
              </div>
              <b>
                {team.emoji} {team.name}
              </b>
              <span>{t('{count} agents', { count: team.agents.length })}</span>
              {team.goal ? <p className="muted" style={{ fontSize: 13, marginTop: 6 }}>{team.goal}</p> : null}
            </Link>
          ))}
        </div>
      )}
    </>
  )
}
