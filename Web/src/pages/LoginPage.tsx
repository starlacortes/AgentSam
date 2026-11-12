import { useState, type FormEvent } from 'react'
import { api, errorMessage } from '../api/client'
import type { Me } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { ErrorBanner, Field, Logo } from '../components/ui'
import { useI18n } from '../i18n'

export function LoginPage() {
  const { signedIn } = useAuth()
  const { t } = useI18n()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      signedIn(await api<Me>('auth/login', { method: 'POST', body: { email, password } }))
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
        <div>
          <div className="kicker">{t('Welcome back')}</div>
          <h1>{t('Sign in')}</h1>
          <p className="lede">{t('Your agent team is waiting.')}</p>
        </div>
        <ErrorBanner message={error} />
        <Field label={t('Email')} type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
        <Field
          label={t('Password')}
          type="password"
          autoComplete="current-password"
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <button className="btn" type="submit" disabled={busy}>
          {busy ? t('Signing in…') : t('Sign in')}
        </button>
        <p className="hint">{t('No account? Ask an admin for an invite link.')}</p>
      </form>
    </div>
  )
}
