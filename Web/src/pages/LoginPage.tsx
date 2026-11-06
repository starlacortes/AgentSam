import { useState, type FormEvent } from 'react'
import { api, errorMessage } from '../api/client'
import type { Me } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { ErrorBanner, Field, Logo } from '../components/ui'

export function LoginPage() {
  const { signedIn } = useAuth()
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
          <div className="kicker">Welcome back</div>
          <h1>Sign in</h1>
          <p className="lede">Your agent team is waiting.</p>
        </div>
        <ErrorBanner message={error} />
        <Field label="Email" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
        <Field
          label="Password"
          type="password"
          autoComplete="current-password"
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <button className="btn" type="submit" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
        <p className="hint">No account? Ask an admin for an invite link.</p>
      </form>
    </div>
  )
}
