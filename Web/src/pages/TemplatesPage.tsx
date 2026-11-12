import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { Team, TemplateCatalog } from '../api/types'
import { Avatar } from '../components/mission'
import { ErrorBanner, Spinner } from '../components/ui'
import { useI18n } from '../i18n'

export function TemplatesPage() {
  const { t } = useI18n()
  useDocumentTitle(t('Templates'))
  const navigate = useNavigate()
  const [catalog, setCatalog] = useState<TemplateCatalog | null>(null)
  const [open, setOpen] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    api<TemplateCatalog>('templates')
      .then(setCatalog)
      .catch((err) => setError(errorMessage(err)))
  }, [])

  async function hire(id: string) {
    setBusy(id)
    setError(null)
    try {
      const team = await api<Team>(`templates/${id}/hire`, { method: 'POST' })
      navigate(`/teams/${team.id}`)
    } catch (err) {
      setError(errorMessage(err))
      setBusy(null)
    }
  }

  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">{t('Templates')}</div>
          <h1>{t('Hire a team in one click.')}</h1>
          <p className="lede">{t('Each squad comes with a coordinator, specialists and a verifier. You can tune every agent afterwards.')}</p>
        </div>
      </div>
      <ErrorBanner message={error} />
      {!catalog ? (
        <Spinner />
      ) : (
        <div className="template-grid">
          {catalog.templates.map(({ template, agents }) => (
            <article className="template-card" key={template.id}>
              <div
                className="template-cover"
                style={{ background: `linear-gradient(135deg, ${template.coverColors[0] ?? '#0f2e20'}, ${template.coverColors[1] ?? '#0a1b14'})` }}
              >
                {template.lowCost ? <span className="chip gold template-badge">{t('low cost')}</span> : null}
                <div className="avatar-stack">
                  {agents.map((a) => (
                    <Avatar key={a.id} name={a.name} role={a.role} size={38} />
                  ))}
                </div>
                <h2>
                  {template.emoji} {template.name}
                </h2>
              </div>
              <div className="template-body">
                <p className="muted">{template.summary}</p>
                <div className="row">
                  {template.capabilities.map((c) => (
                    <span className="chip" key={c}>
                      {c}
                    </span>
                  ))}
                </div>
                {open === template.id ? (
                  <ul className="squad-list">
                    {agents.map((a) => (
                      <li key={a.id}>
                        <b>{a.name}</b> <span className="dim">· {a.title}</span>
                        <div className="dim mono" style={{ fontSize: 11 }}>
                          {t(a.role)} · {a.providerID} / {a.model || t('no model')}
                        </div>
                      </li>
                    ))}
                    <li className="dim">{t('Try: “{example}”', { example: template.example })}</li>
                  </ul>
                ) : null}
                <div className="row">
                  <button className="pill" onClick={() => setOpen(open === template.id ? null : template.id)}>
                    {open === template.id ? t('Hide squad') : t('Meet the squad')}
                  </button>
                  <span className="spacer" />
                  <button className="btn small" disabled={busy !== null} onClick={() => void hire(template.id)}>
                    {busy === template.id ? t('Hiring…') : t('Hire team')}
                  </button>
                </div>
              </div>
            </article>
          ))}
        </div>
      )}
    </>
  )
}
