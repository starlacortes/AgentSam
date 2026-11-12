import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { api, errorMessage } from '../api/client'
import type { PublicAPIToken, TokenCreated } from '../api/types'
import { ErrorBanner, formatDate } from '../components/ui'
import { useI18n } from '../i18n'

/** Personal tokens let someone use the iPhone or Mac app as themselves, instead of the shared server token. */
export function AppTokens() {
  const { t } = useI18n()
  const [tokens, setTokens] = useState<PublicAPIToken[]>([])
  const [name, setName] = useState('')
  const [secret, setSecret] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      setTokens(await api<PublicAPIToken[]>('auth/tokens'))
    } catch (err) {
      setError(errorMessage(err))
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  async function create(event: FormEvent) {
    event.preventDefault()
    setError(null)
    try {
      const created = await api<TokenCreated>('auth/tokens', { method: 'POST', body: { name } })
      setSecret(created.secret)
      setName('')
      await load()
    } catch (err) {
      setError(errorMessage(err))
    }
  }

  async function revoke(id: string) {
    if (!window.confirm(t('Revoke this token? Any app using it will be signed out.'))) return
    try {
      await api(`auth/tokens/${id}`, { method: 'DELETE' })
      await load()
    } catch (err) {
      setError(errorMessage(err))
    }
  }

  return (
    <div className="card stack" style={{ maxWidth: 720 }}>
      <h2>{t('App tokens')}</h2>
      <p className="muted">
        {t('Use a token in the iPhone or Mac app, in place of the server token, to work as yourself with your own role. Each token is shown once.')}
      </p>
      <ErrorBanner message={error} />
      <form className="row" onSubmit={create}>
        <input className="input" style={{ flex: '1 1 220px' }} placeholder={t('Token name, e.g. My iPhone')} maxLength={60} required value={name} onChange={(e) => setName(e.target.value)} />
        <button className="btn small" type="submit">
          {t('Create token')}
        </button>
      </form>
      {secret ? (
        <div className="notice stack" style={{ gap: 8 }}>
          <span>{t('Copy this token now. It won’t be shown again.')}</span>
          <div className="row">
            <code className="mono" style={{ flex: 1, wordBreak: 'break-all' }}>
              {secret}
            </code>
            <button className="btn small ghost" type="button" onClick={() => void navigator.clipboard.writeText(secret)}>
              {t('Copy')}
            </button>
          </div>
        </div>
      ) : null}
      {tokens.length > 0 ? (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>{t('Name')}</th>
                <th>{t('Created')}</th>
                <th>{t('Last used')}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {tokens.map((token) => (
                <tr key={token.id}>
                  <td>{token.name}</td>
                  <td className="dim">{formatDate(token.createdAt)}</td>
                  <td className="dim">{formatDate(token.lastUsedAt)}</td>
                  <td style={{ textAlign: 'right' }}>
                    <button className="btn small ghost" onClick={() => void revoke(token.id)}>
                      {t('Revoke')}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </div>
  )
}
