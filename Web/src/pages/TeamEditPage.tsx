import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { AgentProfile, AgentRole, ProviderStatus, Team } from '../api/types'
import { Avatar } from '../components/mission'
import { ErrorBanner, Spinner } from '../components/ui'
import { useI18n } from '../i18n'

type Draft = Pick<Team, 'name' | 'emoji' | 'goal' | 'agents'>

function newAgent(role: AgentRole, providers: ProviderStatus[]): AgentProfile {
  const provider = providers.find((p) => p.hasKey)?.provider ?? providers[0]?.provider
  return {
    id: crypto.randomUUID(),
    name: role === 'coordinator' ? 'Lead' : role === 'verifier' ? 'Checker' : 'Worker',
    emoji: '',
    title: role === 'coordinator' ? 'Coordinator' : role === 'verifier' ? 'Verifier' : 'Specialist',
    role,
    systemPrompt: '',
    providerID: provider?.id ?? '',
    model: provider?.defaultModel ?? provider?.models[0] ?? '',
  }
}

/** Problems that would stop a mission from running well, shown before saving. */
export function teamWarnings(draft: Draft): string[] {
  const warnings: string[] = []
  const count = (role: AgentRole) => draft.agents.filter((a) => a.role === role).length
  if (count('coordinator') !== 1) warnings.push('A team needs exactly one coordinator.')
  if (count('worker') < 1) warnings.push('Add at least one worker.')
  if (count('verifier') > 1) warnings.push('Use at most one verifier.')
  const names = draft.agents.map((a) => a.name.trim().toLowerCase())
  if (new Set(names).size !== names.length) warnings.push('Agent names must be unique (the plan assigns tasks by name).')
  if (draft.agents.some((a) => !a.name.trim())) warnings.push('Every agent needs a name.')
  if (draft.agents.some((a) => !a.providerID || !a.model)) warnings.push('Every agent needs a provider and model.')
  return warnings
}

export function TeamEditPage() {
  const { id } = useParams()
  const isNew = id === 'new' || !id
  const navigate = useNavigate()
  const { t } = useI18n()
  const [providers, setProviders] = useState<ProviderStatus[]>([])
  const [draft, setDraft] = useState<Draft | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)
  useDocumentTitle(isNew ? t('New team') : draft?.name || t('Team'))

  useEffect(() => {
    void (async () => {
      try {
        const list = await api<ProviderStatus[]>('providers')
        setProviders(list)
        if (isNew) {
          setDraft({ name: '', emoji: '🛡️', goal: '', agents: [newAgent('coordinator', list), newAgent('worker', list), newAgent('verifier', list)] })
        } else {
          const team = await api<Team>(`teams/${id}`)
          setDraft({ name: team.name, emoji: team.emoji, goal: team.goal, agents: team.agents })
        }
      } catch (err) {
        setError(errorMessage(err))
      }
    })()
  }, [id, isNew])

  if (!draft) return error ? <ErrorBanner message={error} /> : <Spinner />

  const warnings = teamWarnings(draft)
  const update = (patch: Partial<Draft>) => {
    setSaved(false)
    setDraft({ ...draft, ...patch })
  }
  const updateAgent = (index: number, patch: Partial<AgentProfile>) =>
    update({ agents: draft.agents.map((a, i) => (i === index ? { ...a, ...patch } : a)) })

  async function save(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const body = { ...draft, agents: draft!.agents.map((a) => ({ ...a, temperature: a.temperature ?? undefined })) }
      const team = isNew
        ? await api<Team>('teams', { method: 'POST', body })
        : await api<Team>(`teams/${id}`, { method: 'PUT', body })
      setSaved(true)
      if (isNew) navigate(`/teams/${team.id}`, { replace: true })
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  async function remove() {
    if (!window.confirm(t('Delete {name}? Past missions stay, but the team can’t run new ones.', { name: draft!.name }))) return
    try {
      await api(`teams/${id}`, { method: 'DELETE' })
      navigate('/teams')
    } catch (err) {
      setError(errorMessage(err))
    }
  }

  return (
    <form onSubmit={save}>
      <div className="page-head">
        <div>
          <div className="kicker">
            <Link to="/teams">{t('Teams')}</Link>
          </div>
          <h1>{isNew ? t('New team') : draft.name || t('Team')}</h1>
        </div>
        <div className="row">
          {!isNew ? (
            <Link className="btn ghost" to={`/missions/new?team=${id}`}>
              {t('Launch a mission')}
            </Link>
          ) : null}
          <button className="btn" type="submit" disabled={busy}>
            {busy ? t('Saving…') : saved ? t('Saved') : t('Save team')}
          </button>
        </div>
      </div>
      <ErrorBanner message={error} />
      {warnings.length > 0 ? (
        <div className="error" style={{ marginBottom: 14 }}>
          {warnings.map((w) => (
            <div key={w}>{t(w)}</div>
          ))}
        </div>
      ) : null}

      <div className="card stack">
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <label className="field" style={{ width: 90 }}>
            <span>{t('Emoji')}</span>
            <input className="input" maxLength={4} value={draft.emoji} onChange={(e) => update({ emoji: e.target.value })} />
          </label>
          <label className="field" style={{ flex: 1, minWidth: 200 }}>
            <span>{t('Team name')}</span>
            <input className="input" required maxLength={80} value={draft.name} onChange={(e) => update({ name: e.target.value })} />
          </label>
        </div>
        <label className="field">
          <span>{t('Goal')}</span>
          <input className="input" value={draft.goal} onChange={(e) => update({ goal: e.target.value })} placeholder={t('What this team is for')} />
        </label>
      </div>

      {draft.agents.map((agent, index) => {
        const provider = providers.find((p) => p.provider.id === agent.providerID)
        const models = provider?.provider.models ?? []
        return (
          <div className="card stack" key={agent.id}>
            <div className="row">
              <Avatar name={agent.name || '?'} role={agent.role} size={44} />
              <div style={{ flex: 1 }}>
                <b style={{ color: 'var(--bright)' }}>{agent.name || t('Unnamed agent')}</b>
                <div className="dim mono" style={{ fontSize: 11 }}>
                  {t(agent.role)}
                </div>
              </div>
              <button type="button" className="btn small danger" onClick={() => update({ agents: draft.agents.filter((_, i) => i !== index) })}>
                {t('Remove')}
              </button>
            </div>
            <div className="grid-3">
              <label className="field">
                <span>{t('Name')}</span>
                <input className="input" value={agent.name} onChange={(e) => updateAgent(index, { name: e.target.value })} />
              </label>
              <label className="field">
                <span>{t('Title')}</span>
                <input className="input" value={agent.title} onChange={(e) => updateAgent(index, { title: e.target.value })} />
              </label>
              <label className="field">
                <span>{t('Role')}</span>
                <select className="select" value={agent.role} onChange={(e) => updateAgent(index, { role: e.target.value as AgentRole })}>
                  <option value="coordinator">{t('Coordinator')}</option>
                  <option value="worker">{t('Worker')}</option>
                  <option value="verifier">{t('Verifier')}</option>
                </select>
              </label>
              <label className="field">
                <span>{t('Provider')}</span>
                <select
                  className="select"
                  value={agent.providerID}
                  onChange={(e) => {
                    const next = providers.find((p) => p.provider.id === e.target.value)?.provider
                    updateAgent(index, { providerID: e.target.value, model: next?.defaultModel ?? next?.models[0] ?? '' })
                  }}
                >
                  {!provider ? <option value={agent.providerID}>{agent.providerID || t('Choose…')}</option> : null}
                  {providers.map((p) => (
                    <option key={p.provider.id} value={p.provider.id}>
                      {p.provider.name}
                      {p.hasKey ? '' : ` ${t('(no key)')}`}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                <span>{t('Model')}</span>
                <select className="select" value={agent.model} onChange={(e) => updateAgent(index, { model: e.target.value })}>
                  {!models.includes(agent.model) ? <option value={agent.model}>{agent.model || t('Choose…')}</option> : null}
                  {models.map((m) => (
                    <option key={m} value={m}>
                      {m}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                <span>{t('Temperature')}</span>
                <input
                  className="input"
                  type="number"
                  min={0}
                  max={2}
                  step={0.1}
                  placeholder={t('default')}
                  value={agent.temperature ?? ''}
                  onChange={(e) => updateAgent(index, { temperature: e.target.value === '' ? undefined : Number(e.target.value) })}
                />
              </label>
            </div>
            <label className="field">
              <span>{t('System prompt')}</span>
              <textarea className="textarea" value={agent.systemPrompt} onChange={(e) => updateAgent(index, { systemPrompt: e.target.value })} />
            </label>
          </div>
        )
      })}

      <div className="row" style={{ marginTop: 16 }}>
        <button type="button" className="btn ghost" onClick={() => update({ agents: [...draft.agents, newAgent('worker', providers)] })}>
          {t('Add worker')}
        </button>
        {!draft.agents.some((a) => a.role === 'verifier') ? (
          <button type="button" className="btn ghost" onClick={() => update({ agents: [...draft.agents, newAgent('verifier', providers)] })}>
            {t('Add verifier')}
          </button>
        ) : null}
        <span className="spacer" />
        {!isNew ? (
          <button type="button" className="btn danger" onClick={() => void remove()}>
            {t('Delete team')}
          </button>
        ) : null}
      </div>
    </form>
  )
}
