import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { api, errorMessage } from '../api/client'
import type { InviteCreated, PublicInvite, PublicUser, UserRole } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { ErrorBanner, formatDate, Spinner } from '../components/ui'
import { useI18n } from '../i18n'

export function PeoplePage() {
  const { t } = useI18n()
  useDocumentTitle(t('People'))
  const { me } = useAuth()
  const [users, setUsers] = useState<PublicUser[] | null>(null)
  const [invites, setInvites] = useState<PublicInvite[]>([])
  const [error, setError] = useState<string | null>(null)
  const [inviteEmail, setInviteEmail] = useState('')
  const [inviteRole, setInviteRole] = useState<UserRole>('member')
  const [newLink, setNewLink] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  const load = useCallback(async () => {
    try {
      const [u, i] = await Promise.all([api<PublicUser[]>('users'), api<PublicInvite[]>('invites')])
      setUsers(u)
      setInvites(i)
    } catch (err) {
      setError(errorMessage(err))
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  async function run(action: () => Promise<unknown>) {
    setError(null)
    try {
      await action()
      await load()
    } catch (err) {
      setError(errorMessage(err))
    }
  }

  async function invite(event: FormEvent) {
    event.preventDefault()
    await run(async () => {
      const created = await api<InviteCreated>('invites', { method: 'POST', body: { email: inviteEmail, role: inviteRole } })
      setNewLink(`${window.location.origin}${created.path}`)
      setCopied(false)
      setInviteEmail('')
    })
  }

  async function copyLink() {
    if (!newLink) return
    await navigator.clipboard.writeText(newLink)
    setCopied(true)
  }

  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">{t('People')}</div>
          <h1>{t('Who can use this server')}</h1>
          <p className="lede">{t('Everyone shares the same teams and missions. Admins also manage people and provider keys.')}</p>
        </div>
        <Link className="btn ghost" to="/provisioning">{t('Provision accounts in bulk →')}</Link>
      </div>

      <ErrorBanner message={error} />

      <form className="card stack" onSubmit={invite}>
        <h2>{t('Invite someone')}</h2>
        <div className="row">
          <input
            className="input"
            style={{ flex: '1 1 240px' }}
            type="email"
            placeholder="name@example.com"
            required
            value={inviteEmail}
            onChange={(e) => setInviteEmail(e.target.value)}
            aria-label={t('Email to invite')}
          />
          <select className="select" style={{ width: 140 }} value={inviteRole} onChange={(e) => setInviteRole(e.target.value as UserRole)} aria-label={t('Role')}>
            <option value="member">{t('Member')}</option>
            <option value="admin">{t('Admin')}</option>
          </select>
          <button className="btn" type="submit">
            {t('Create invite link')}
          </button>
        </div>
        {newLink ? (
          <div className="notice stack" style={{ gap: 8 }}>
            <span>{t('Send this link to them. It works once and expires in 7 days. It won’t be shown again.')}</span>
            <div className="row">
              <code className="mono" style={{ wordBreak: 'break-all', flex: 1 }}>
                {newLink}
              </code>
              <button type="button" className="btn small ghost" onClick={() => void copyLink()}>
                {copied ? t('Copied') : t('Copy')}
              </button>
            </div>
          </div>
        ) : null}
      </form>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>{t('Members')}</h2>
        {!users ? (
          <Spinner />
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>{t('Name')}</th>
                  <th>{t('Email')}</th>
                  <th>{t('Role')}</th>
                  <th>{t('Last sign-in')}</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {users.map((user) => {
                  const isMe = user.id === me?.user?.id
                  return (
                    <tr key={user.id}>
                      <td>
                        {user.name} {isMe ? <span className="chip">{t('you')}</span> : null}{' '}
                        {user.disabled ? <span className="chip danger">{t('disabled')}</span> : null}
                      </td>
                      <td className="muted">{user.email}</td>
                      <td>
                        <select
                          className="select"
                          style={{ width: 120, padding: '6px 10px' }}
                          value={user.role}
                          aria-label={t('Role for {name}', { name: user.name })}
                          onChange={(e) => void run(() => api(`users/${user.id}`, { method: 'PATCH', body: { role: e.target.value } }))}
                        >
                          <option value="member">{t('Member')}</option>
                          <option value="admin">{t('Admin')}</option>
                        </select>
                      </td>
                      <td className="dim">{formatDate(user.lastLoginAt)}</td>
                      <td>
                        {isMe ? null : (
                          <div className="row" style={{ justifyContent: 'flex-end' }}>
                            <button
                              className="btn small ghost"
                              onClick={() => void run(() => api(`users/${user.id}`, { method: 'PATCH', body: { disabled: !user.disabled } }))}
                            >
                              {user.disabled ? t('Enable') : t('Disable')}
                            </button>
                            <button
                              className="btn small danger"
                              onClick={() => {
                                if (window.confirm(t('Remove {name}? They’ll be signed out immediately.', { name: user.name }))) {
                                  void run(() => api(`users/${user.id}`, { method: 'DELETE' }))
                                }
                              }}
                            >
                              {t('Remove')}
                            </button>
                          </div>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {invites.length > 0 ? (
        <div className="card">
          <h2 style={{ marginBottom: 12 }}>{t('Pending invites')}</h2>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>{t('Email')}</th>
                  <th>{t('Role')}</th>
                  <th>{t('Expires')}</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {invites.map((inv) => (
                  <tr key={inv.id}>
                    <td>{inv.email}</td>
                    <td>{t(inv.role)}</td>
                    <td className="dim">{formatDate(inv.expiresAt)}</td>
                    <td style={{ textAlign: 'right' }}>
                      <button className="btn small ghost" onClick={() => void run(() => api(`invites/${inv.id}`, { method: 'DELETE' }))}>
                        {t('Revoke')}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ) : null}
    </>
  )
}
