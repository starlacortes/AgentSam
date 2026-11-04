import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import type { Me } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { ErrorBanner, Field, Logo } from '../components/ui'

/** Shown only while the server has no accounts. Creating the first admin needs the AGENTSAM_TOKEN. */
export function SetupPage() {
  const { signedIn } = useAuth()
  const navigate = useNavigate()
  const [form, setForm] = useState({ setupToken: '', name: '', email: '', password: '', confirm: '' })
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const set = (key: keyof typeof form) => (e: { target: { value: string } }) => setForm({ ...form, [key]: e.target.value })

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (form.password !== form.confirm) {
      setError('Passwords don’t match')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const { confirm: _confirm, ...body } = form
      const me = await api<Me>('auth/setup', { method: 'POST', body })
      signedIn(me)
      navigate('/welcome', { replace: true })
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
          <div className="kicker">First run</div>
          <h1>Create the admin account</h1>
          <p className="lede">
            Prove you own this server with its <b>AGENTSAM_TOKEN</b> (in Railway’s variables), then pick your sign-in.
          </p>
        </div>
        <ErrorBanner message={error} />
        <Field label="Server token" type="password" autoComplete="off" required value={form.setupToken} onChange={set('setupToken')} />
        <Field label="Your name" autoComplete="name" required value={form.name} onChange={set('name')} />
        <Field label="Email" type="email" autoComplete="username" required value={form.email} onChange={set('email')} />
        <Field
          label="Password"
          type="password"
          autoComplete="new-password"
          minLength={12}
          required
          value={form.password}
          onChange={set('password')}
          hint="At least 12 characters."
        />
        <Field label="Confirm password" type="password" autoComplete="new-password" required value={form.confirm} onChange={set('confirm')} />
        <button className="btn" type="submit" disabled={busy}>
          {busy ? 'Creating…' : 'Create admin and sign in'}
        </button>
      </form>
    </div>
  )
}
