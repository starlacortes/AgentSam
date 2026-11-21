import { Navigate, Route, Routes, useLocation } from 'react-router-dom'
import { useAuth } from './auth/AuthContext'
import { Layout } from './components/Layout'
import { Spinner } from './components/ui'
import { CoordinatorPage } from './pages/CoordinatorPage'
import { MissionPage } from './pages/MissionPage'
import { MissionsPage } from './pages/MissionsPage'
import { InvitePage } from './pages/InvitePage'
import { LoginPage } from './pages/LoginPage'
import { ProvisioningPage } from './pages/ProvisioningPage'
import { SettingsPage } from './pages/SettingsPage'
import { SetupPage } from './pages/SetupPage'

export function App() {
  const { state, isAdmin } = useAuth()
  const location = useLocation()

  // The invite page works whether or not someone is signed in.
  if (location.pathname === '/invite') return <InvitePage />

  switch (state.status) {
    case 'loading':
      return (
        <div className="center">
          <Spinner />
        </div>
      )
    case 'needsSetup':
      return <SetupPage />
    case 'signedOut':
      return <LoginPage />
    case 'signedIn':
      return (
        <Routes>
          <Route element={<Layout />}>
            <Route index element={<CoordinatorPage />} />
            <Route path="chats/:id" element={<CoordinatorPage />} />
            <Route path="coordinator" element={<Navigate to="/" replace />} />
            <Route path="missions" element={<MissionsPage />} />
            {/* Teams and templates are now Ada's skills, run behind the scenes. Old links go to chat. */}
            <Route path="missions/new" element={<Navigate to="/" replace />} />
            <Route path="missions/:id" element={<MissionPage />} />
            <Route path="teams/*" element={<Navigate to="/" replace />} />
            <Route path="templates" element={<Navigate to="/" replace />} />
            {/* Every setting lives under /settings. Old addresses (and Google's sign-in return) still work. */}
            <Route path="settings" element={<Navigate to="/settings/connections" replace />} />
            <Route path="settings/:section" element={<SettingsPage />} />
            <Route path="connectors" element={<KeepQuery to="/settings/connections" />} />
            <Route path="account" element={<Navigate to="/settings/account" replace />} />
            <Route path="people" element={<Navigate to="/settings/people" replace />} />
            <Route path="welcome" element={<Navigate to="/?guide=1" replace />} />
            {isAdmin ? <Route path="provisioning" element={<ProvisioningPage />} /> : null}
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      )
  }
}

/** Redirects while keeping the query string, e.g. `?connected=gmail` after Google sign-in. */
function KeepQuery({ to }: { to: string }) {
  const { search } = useLocation()
  return <Navigate to={`${to}${search}`} replace />
}
