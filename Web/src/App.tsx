import { Navigate, Route, Routes, useLocation } from 'react-router-dom'
import { useAuth } from './auth/AuthContext'
import { Layout } from './components/Layout'
import { Spinner } from './components/ui'
import { AccountPage } from './pages/AccountPage'
import { ConnectorsPage } from './pages/ConnectorsPage'
import { CoordinatorPage } from './pages/CoordinatorPage'
import { MissionPage } from './pages/MissionPage'
import { MissionsPage } from './pages/MissionsPage'
import { NewMissionPage } from './pages/NewMissionPage'
import { InvitePage } from './pages/InvitePage'
import { LoginPage } from './pages/LoginPage'
import { PeoplePage } from './pages/PeoplePage'
import { ProvisioningPage } from './pages/ProvisioningPage'
import { SettingsPage } from './pages/SettingsPage'
import { SetupPage } from './pages/SetupPage'
import { TeamEditPage } from './pages/TeamEditPage'
import { TeamsPage } from './pages/TeamsPage'
import { TemplatesPage } from './pages/TemplatesPage'

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
            <Route path="missions/new" element={<NewMissionPage />} />
            <Route path="missions/:id" element={<MissionPage />} />
            <Route path="teams" element={<TeamsPage />} />
            <Route path="teams/:id" element={<TeamEditPage />} />
            <Route path="templates" element={<TemplatesPage />} />
            <Route path="account" element={<AccountPage />} />
            <Route path="welcome" element={<Navigate to="/?guide=1" replace />} />
            {isAdmin ? <Route path="people" element={<PeoplePage />} /> : null}
            {isAdmin ? <Route path="provisioning" element={<ProvisioningPage />} /> : null}
            {isAdmin ? <Route path="settings" element={<SettingsPage />} /> : null}
            {isAdmin ? <Route path="connectors" element={<ConnectorsPage />} /> : null}
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      )
  }
}
