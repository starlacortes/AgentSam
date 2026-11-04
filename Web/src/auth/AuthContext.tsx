import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api, setUnauthorizedHandler } from '../api/client'
import type { Me } from '../api/types'

type AuthState =
  | { status: 'loading' }
  | { status: 'needsSetup' }
  | { status: 'signedOut' }
  | { status: 'signedIn'; me: Me }

interface AuthContextValue {
  state: AuthState
  me: Me | null
  isAdmin: boolean
  signedIn: (me: Me) => void
  signOut: () => Promise<void>
  refresh: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<AuthState>({ status: 'loading' })

  const refresh = useCallback(async () => {
    try {
      const me = await api<Me>('auth/me')
      setState({ status: 'signedIn', me })
    } catch {
      try {
        const status = await api<{ needsSetup: boolean }>('auth/status')
        setState({ status: status.needsSetup ? 'needsSetup' : 'signedOut' })
      } catch {
        setState({ status: 'signedOut' })
      }
    }
  }, [])

  useEffect(() => {
    void refresh()
    setUnauthorizedHandler(() => setState({ status: 'signedOut' }))
    return () => setUnauthorizedHandler(null)
  }, [refresh])

  const value = useMemo<AuthContextValue>(() => {
    const me = state.status === 'signedIn' ? state.me : null
    return {
      state,
      me,
      isAdmin: me?.role === 'admin',
      signedIn: (next) => setState({ status: 'signedIn', me: next }),
      signOut: async () => {
        try {
          await api('auth/logout', { method: 'POST' })
        } finally {
          setState({ status: 'signedOut' })
        }
      },
      refresh,
    }
  }, [state, refresh])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthContextValue {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth must be used inside AuthProvider')
  return value
}
