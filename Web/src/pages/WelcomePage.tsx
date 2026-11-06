import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { Mission, ProviderStatus, ProviderTestResult, Team, TemplateCatalog } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { Avatar } from '../components/mission'
import { ErrorBanner, Spinner } from '../components/ui'

type Step = 'provider' | 'team' | 'mission'

/** Guided setup, like the apps: connect a provider (admins), hire a team, launch a first mission. */
export function WelcomePage() {
  useDocumentTitle('Get started')
  const { isAdmin, me } = useAuth()
  const navigate = useNavigate()
  const steps: Step[] = isAdmin ? ['provider', 'team', 'mission'] : ['team', 'mission']
  const [step, setStep] = useState<Step>(steps[0] ?? 'team')
  const [providers, setProviders] = useState<ProviderStatus[]>([])
  const [providerID, setProviderID] = useState('anthropic')
  const [key, setKey] = useState('')
  const [test, setTest] = useState<ProviderTestResult | null>(null)
  const [catalog, setCatalog] = useState<TemplateCatalog | null>(null)
  const [team, setTeam] = useState<Team | null>(null)
  const [objective, setObjective] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    api<ProviderStatus[]>('providers')
      .then((list) => {
        setProviders(list)
        setProviderID(list.find((p) => p.hasKey)?.provider.id ?? list[0]?.provider.id ?? 'anthropic')
      })
      .catch((err) => setError(errorMessage(err)))
    api<TemplateCatalog>('templates')
      .then(setCatalog)
      .catch((err) => setError(errorMessage(err)))
  }, [])

  const index = steps.indexOf(step)
  const selected = providers.find((p) => p.provider.id === providerID)

  async function guard(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  const connect = () =>
    guard(async () => {
      if (key.trim()) await api(`providers/${providerID}/key`, { method: 'POST', body: { key } })
      const result = await api<ProviderTestResult>(`providers/${providerID}/test`, { method: 'POST' })
      setTest(result)
      if (result.ok) {
        setKey('')
        setProviders(await api<ProviderStatus[]>('providers'))
      }
    })

  const hire = (id: string) =>
    guard(async () => {
      setTeam(await api<Team>(`templates/${id}/hire`, { method: 'POST' }))
      setStep('mission')
    })

  const launch = () =>
    guard(async () => {
      if (!team) return
      const mission = await api<Mission>('missions', { method: 'POST', body: { teamID: team.id, objective } })
      navigate(`/missions/${mission.id}`)
    })

  return (
    <div className="welcome card">
      <aside className="steprail">
        {steps.map((s, i) => (
          <div key={s} className={`stepline ${s === step ? 'on' : ''} ${i < index ? 'done' : ''}`}>
            <span className="n">{i + 1}</span>
            <span className="lbl">{s === 'provider' ? 'Connect models' : s === 'team' ? 'Hire a team' : 'First mission'}</span>
          </div>
        ))}
        <button className="pill" style={{ marginTop: 'auto' }} onClick={() => navigate('/')}>
          Skip setup
        </button>
      </aside>
      <section className="step-body stack">
        <ErrorBanner message={error} />

        {step === 'provider' ? (
          <>
            <div>
              <div className="kicker">Step 1</div>
              <h1>Connect your models.</h1>
              <p className="lede">Bring your own key. It’s stored on the server and every mission uses it, for everyone.</p>
            </div>
            <div className="team-picker">
              {providers.map((p) => (
                <button
                  key={p.provider.id}
                  className={p.provider.id === providerID ? 'pick-card sel' : 'pick-card'}
                  onClick={() => {
                    setProviderID(p.provider.id)
                    setTest(null)
                  }}
                >
                  <b>{p.provider.name}</b>
                  <span>{p.hasKey ? 'key saved' : p.provider.defaultModel}</span>
                </button>
              ))}
            </div>
            <div className="row">
              <input
                className="input mono"
                style={{ flex: '1 1 260px' }}
                type="password"
                autoComplete="off"
                placeholder={selected?.hasKey ? 'Key saved. Paste a new one to replace it.' : `Paste your ${selected?.provider.name ?? ''} API key`}
                value={key}
                onChange={(e) => setKey(e.target.value)}
              />
              <button className="btn" disabled={busy || (!key.trim() && !selected?.hasKey)} onClick={() => void connect()}>
                {busy ? 'Testing…' : 'Test connection'}
              </button>
            </div>
            {test ? <div className={test.ok ? 'notice' : 'error'}>{test.message}</div> : null}
            <div className="row">
              <span className="spacer" />
              <button className="btn" disabled={!providers.some((p) => p.hasKey)} onClick={() => setStep('team')}>
                Next
              </button>
            </div>
          </>
        ) : null}

        {step === 'team' ? (
          <>
            <div>
              <div className="kicker">Step {index + 1}</div>
              <h1>Who do you need?</h1>
              <p className="lede">Pick a squad. You can rename agents and change their models later in Teams.</p>
            </div>
            {!catalog ? (
              <Spinner />
            ) : (
              <div className="team-picker">
                {catalog.templates.map(({ template, agents }) => (
                  <button key={template.id} className="pick-card" disabled={busy} onClick={() => void hire(template.id)}>
                    <div className="avatar-stack">
                      {agents.map((a) => (
                        <Avatar key={a.id} name={a.name} role={a.role} size={34} />
                      ))}
                    </div>
                    <b>
                      {template.emoji} {template.name}
                    </b>
                    <span>{template.capabilities.join(' · ')}</span>
                  </button>
                ))}
              </div>
            )}
          </>
        ) : null}

        {step === 'mission' ? (
          <>
            <div>
              <div className="kicker">Step {index + 1}</div>
              <h1>Your first mission.</h1>
              <p className="lede">
                {team ? (
                  <>
                    <b>{team.name}</b> is ready, {me?.name}. What should they work on?
                  </>
                ) : (
                  'Hire a team first.'
                )}
              </p>
            </div>
            <textarea className="textarea" value={objective} onChange={(e) => setObjective(e.target.value)} placeholder="Describe the objective" />
            <div className="row">
              {(catalog?.missionIdeas ?? []).map((idea) => (
                <button key={idea} className="idea" onClick={() => setObjective(idea)}>
                  {idea}
                </button>
              ))}
            </div>
            <div className="row">
              <button className="btn" disabled={busy || !team || !objective.trim()} onClick={() => void launch()}>
                {busy ? 'Launching…' : 'Launch mission'}
              </button>
            </div>
          </>
        ) : null}
      </section>
    </div>
  )
}
