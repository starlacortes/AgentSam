import { useEffect, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import type { InvitePreview, Me } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { ErrorBanner, Field, Logo, Spinner } from '../components/ui'
import { useI18n } from '../i18n'

/** /invite#<secret>. The secret lives in the fragment, so it never appears in server or proxy logs. */
export function InvitePage() {
  const { signedIn } = useAuth()
  const navigate = useNavigate()
  const { t } = useI18n()
  const [secret] = useState(() => window.location.hash.replace(/^#/, ''))
  const [preview, setPreview] = useState<InvitePreview | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [form, setForm] = useState({ name: '', password: '', confirm: '' })
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!secret) {
      setLoadError(t('This invite link is incomplete. Ask your admin to send it again.'))
      return
    }
    api<InvitePreview>(`auth/invite/${encodeURIComponent(secret)}`)
      .then(setPreview)
      .catch((err) => setLoadError(errorMessage(err)))
  }, [secret, t])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (form.password !== form.confirm) {
      setError(t('Passwords don’t match'))
      return
    }
    setBusy(true)
    setError(null)
    try {
      const me = await api<Me>('auth/accept-invite', {
        method: 'POST',
        body: { secret, name: form.name, password: form.password },
      })
      history.replaceState(null, '', '/')
      signedIn(me)
      navigate('/', { replace: true })
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="auth-wrap">
      <form className="card auth-card stack" onSubmit={submit}>
        <Logo />
        {loadError ? (
          <>
            <h1>{t('Invite unavailable')}</h1>
            <ErrorBanner message={loadError} />
            <a className="btn ghost" href="/">
              {t('Go to sign in')}
            </a>
          </>
        ) : !preview ? (
          <Spinner />
        ) : (
          <>
            <div>
              <div className="kicker">{t('You’re invited')}</div>
              <h1>{t('Join AgentSam')}</h1>
              <p className="lede">{t('Creating an account for {email} as {role}.', { email: preview.email, role: preview.role === 'admin' ? t('an admin') : t('a member') })}</p>
            </div>
            <ErrorBanner message={error} />
            <Field label={t('Your name')} autoComplete="name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <Field
              label={t('Password')}
              type="password"
              autoComplete="new-password"
              minLength={12}
              required
              value={form.password}
              onChange={(e) => setForm({ ...form, password: e.target.value })}
              hint={t('At least 12 characters.')}
            />
            <Field
              label={t('Confirm password')}
              type="password"
              autoComplete="new-password"
              required
              value={form.confirm}
              onChange={(e) => setForm({ ...form, confirm: e.target.value })}
            />
            <button className="btn" type="submit" disabled={busy}>
              {busy ? t('Creating account…') : t('Create account')}
            </button>
          </>
        )}
      </form>
    </div>
  )
}
