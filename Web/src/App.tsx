import { Navigate, Route, Routes, useLocation } from 'react-router-dom'
import { useAuth } from './auth/AuthContext'
import { Layout } from './components/Layout'
import { Spinner } from './components/ui'
import { AccountPage } from './pages/AccountPage'
import { MissionPage } from './pages/MissionPage'
import { MissionsPage } from './pages/MissionsPage'
import { NewMissionPage } from './pages/NewMissionPage'
import { InvitePage } from './pages/InvitePage'
import { LoginPage } from './pages/LoginPage'
import { PeoplePage } from './pages/PeoplePage'
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
            <Route index element={<MissionsPage />} />
            <Route path="missions/new" element={<NewMissionPage />} />
            <Route path="missions/:id" element={<MissionPage />} />
            <Route path="account" element={<AccountPage />} />
            {isAdmin ? <Route path="people" element={<PeoplePage />} /> : null}
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      )
  }
}
