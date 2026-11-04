import { NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { Logo } from './ui'

export function Layout() {
  const { me, isAdmin } = useAuth()
  const pill = ({ isActive }: { isActive: boolean }) => (isActive ? 'pill active' : 'pill')

  return (
    <>
      <header className="topbar">
        <NavLink to="/" className="logo" aria-label="AgentSam home">
          <Logo />
        </NavLink>
        <nav className="nav" aria-label="Main">
          <NavLink to="/" end className={pill}>
            Missions
          </NavLink>
          <NavLink to="/teams" className={pill}>
            Teams
          </NavLink>
          <NavLink to="/templates" className={pill}>
            Templates
          </NavLink>
          {isAdmin ? (
            <NavLink to="/settings" className={pill}>
              Providers
            </NavLink>
          ) : null}
          {isAdmin ? (
            <NavLink to="/people" className={pill}>
              People
            </NavLink>
          ) : null}
          <NavLink to="/account" className={pill}>
            Account
          </NavLink>
        </nav>
        <span className="whoami">
          {me?.name} · {me?.role}
        </span>
      </header>
      <main className="page">
        <Outlet />
      </main>
    </>
  )
}
