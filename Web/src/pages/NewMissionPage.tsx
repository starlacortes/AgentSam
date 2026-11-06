import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import type { Mission, Team } from '../api/types'
import { ErrorBanner, Spinner } from '../components/ui'
import { Avatar } from '../components/mission'

export function NewMissionPage() {
  const navigate = useNavigate()
  const [teams, setTeams] = useState<Team[] | null>(null)
  const [teamID, setTeamID] = useState<string>('')
  const [objective, setObjective] = useState('')
  const [ideas, setIdeas] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    api<Team[]>('teams')
      .then((list) => {
        setTeams(list)
        const preset = new URLSearchParams(window.location.search).get('team')
        setTeamID(list.find((t) => t.id === preset)?.id ?? list[0]?.id ?? '')
      })
      .catch((err) => setError(errorMessage(err)))
    api<{ missionIdeas: string[] }>('templates')
      .then((catalog) => setIdeas(catalog.missionIdeas))
      .catch(() => setIdeas([]))
  }, [])

  async function launch(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const mission = await api<Mission>('missions', { method: 'POST', body: { teamID, objective } })
      navigate(`/missions/${mission.id}`)
    } catch (err) {
      setError(errorMessage(err))
      setBusy(false)
    }
  }

  return (
    <form onSubmit={launch}>
      <div className="page-head">
        <div>
          <div className="kicker">New mission</div>
          <h1>What should the team do?</h1>
          <p className="lede">The coordinator turns your objective into tasks, workers run them in parallel, and the verifier checks the results.</p>
        </div>
      </div>
      <ErrorBanner message={error} />
      {!teams ? (
        <Spinner />
      ) : teams.length === 0 ? (
        <div className="card empty">
          <p style={{ marginBottom: 14 }}>You need a team first.</p>
          <Link className="btn" to="/templates">
            Hire a team
          </Link>
        </div>
      ) : (
        <div className="stack">
          <div className="team-picker" role="radiogroup" aria-label="Team">
            {teams.map((team) => (
              <button
                type="button"
                role="radio"
                aria-checked={team.id === teamID}
                key={team.id}
                className={team.id === teamID ? 'pick-card sel' : 'pick-card'}
                onClick={() => setTeamID(team.id)}
              >
                <div className="avatar-stack">
                  {team.agents.slice(0, 5).map((a) => (
                    <Avatar key={a.id} name={a.name} role={a.role} size={34} />
                  ))}
                </div>
                <b>
                  {team.emoji} {team.name}
                </b>
                <span>{team.agents.length} agents</span>
              </button>
            ))}
          </div>
          <label className="field">
            <span>Objective</span>
            <textarea
              className="textarea"
              required
              maxLength={8000}
              placeholder="e.g. Research the top five open-source vector databases and write a comparison with a recommendation."
              value={objective}
              onChange={(e) => setObjective(e.target.value)}
            />
          </label>
          {ideas.length > 0 ? (
            <div className="row" aria-label="Ideas">
              {ideas.slice(0, 6).map((idea) => (
                <button type="button" key={idea} className="idea" onClick={() => setObjective(idea)}>
                  {idea}
                </button>
              ))}
            </div>
          ) : null}
          <div className="row">
            <button className="btn" type="submit" disabled={busy || !teamID || !objective.trim()}>
              {busy ? 'Launching…' : 'Launch mission'}
            </button>
            <span className="hint">Runs on the server with the provider keys your admin configured.</span>
          </div>
        </div>
      )}
    </form>
  )
}
