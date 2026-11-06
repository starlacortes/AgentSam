import { useState, type FormEvent } from 'react'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { Ack } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { ErrorBanner, Field } from '../components/ui'
import { AppTokens } from './AppTokens'

export function AccountPage() {
  useDocumentTitle('Account')
  const { me, signOut } = useAuth()
  const [form, setForm] = useState({ currentPassword: '', newPassword: '', confirm: '' })
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function changePassword(event: FormEvent) {
    event.preventDefault()
    setError(null)
    setNotice(null)
    if (form.newPassword !== form.confirm) {
      setError('New passwords don’t match')
      return
    }
    setBusy(true)
    try {
      const ack = await api<Ack>('auth/password', {
        method: 'POST',
        body: { currentPassword: form.currentPassword, newPassword: form.newPassword },
      })
      setNotice(ack.detail ?? 'Password changed.')
      setForm({ currentPassword: '', newPassword: '', confirm: '' })
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">Account</div>
          <h1>{me?.name}</h1>
          <p className="lede">
            {me?.user?.email ?? 'Signed in with the server token'} · {me?.role}
          </p>
        </div>
        <button className="btn ghost" onClick={() => void signOut()}>
          Sign out
        </button>
      </div>

      {me?.via === 'session' ? (
        <form className="card stack" style={{ maxWidth: 480 }} onSubmit={changePassword}>
          <h2>Change password</h2>
          <ErrorBanner message={error} />
          {notice ? <div className="notice">{notice}</div> : null}
          <Field
            label="Current password"
            type="password"
            autoComplete="current-password"
            required
            value={form.currentPassword}
            onChange={(e) => setForm({ ...form, currentPassword: e.target.value })}
          />
          <Field
            label="New password"
            type="password"
            autoComplete="new-password"
            minLength={12}
            required
            value={form.newPassword}
            onChange={(e) => setForm({ ...form, newPassword: e.target.value })}
            hint="At least 12 characters. Your other sessions will be signed out."
          />
          <Field
            label="Confirm new password"
            type="password"
            autoComplete="new-password"
            required
            value={form.confirm}
            onChange={(e) => setForm({ ...form, confirm: e.target.value })}
          />
          <div>
            <button className="btn" type="submit" disabled={busy}>
              {busy ? 'Saving…' : 'Change password'}
            </button>
          </div>
        </form>
      ) : null}
      {me?.via === 'session' ? <AppTokens /> : null}
    </>
  )
}
