import { useEffect, useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { Logo } from './ui'

interface NavItem {
  to: string
  label: string
  /** Shorter label for the phone tab bar, where five tabs share the width. */
  tabLabel?: string
  end?: boolean
}

export function Layout() {
  const { me, isAdmin, signOut } = useAuth()
  const location = useLocation()
  const [moreOpen, setMoreOpen] = useState(false)
  const pill = ({ isActive }: { isActive: boolean }) => (isActive ? 'pill active' : 'pill')

  const primary: NavItem[] = [
    { to: '/', label: 'Missions', end: true },
    { to: '/coordinator', label: 'Coordinator', tabLabel: 'Chat' },
    { to: '/teams', label: 'Teams' },
    { to: '/templates', label: 'Templates' },
  ]
  const secondary: NavItem[] = [
    ...(isAdmin ? [{ to: '/settings', label: 'Providers' }] : []),
    ...(isAdmin ? [{ to: '/connectors', label: 'Connectors' }] : []),
    ...(isAdmin ? [{ to: '/people', label: 'People' }] : []),
    { to: '/account', label: 'Account' },
  ]

  // Close the phone menu whenever the page changes.
  useEffect(() => setMoreOpen(false), [location.pathname])

  const moreActive = secondary.some((item) => location.pathname.startsWith(item.to))

  return (
    <>
      <header className="topbar">
        <NavLink to="/" className="logo" aria-label="AgentSam home">
          <Logo />
        </NavLink>
        <nav className="nav" aria-label="Main">
          {[...primary, ...secondary].map((item) => (
            <NavLink key={item.to} to={item.to} end={item.end} className={pill}>
              {item.label}
            </NavLink>
          ))}
        </nav>
        <span className="whoami">
          {me?.name} · {me?.role}
        </span>
        <button className="pill signout" onClick={() => void signOut()}>
          Sign out
        </button>
      </header>
      <main className="page">
        <Outlet />
      </main>

      {/* Phone navigation: the three main sections plus a "More" sheet for everything else. */}
      <nav className="tabbar" aria-label="Main">
        {primary.map((item) => (
          <NavLink key={item.to} to={item.to} end={item.end} className={({ isActive }) => (isActive ? 'tab active' : 'tab')}>
            {item.tabLabel ?? item.label}
          </NavLink>
        ))}
        <button className={moreActive || moreOpen ? 'tab active' : 'tab'} aria-expanded={moreOpen} onClick={() => setMoreOpen((open) => !open)}>
          More
        </button>
      </nav>
      {moreOpen ? (
        <>
          <div className="sheet-backdrop" onClick={() => setMoreOpen(false)} />
          <div className="sheet" role="menu">
            <div className="sheet-who mono">
              {me?.name} · {me?.role}
            </div>
            {secondary.map((item) => (
              <NavLink key={item.to} to={item.to} role="menuitem" className={({ isActive }) => (isActive ? 'sheet-item active' : 'sheet-item')}>
                {item.label}
              </NavLink>
            ))}
            <button className="sheet-item danger" role="menuitem" onClick={() => void signOut()}>
              Sign out
            </button>
          </div>
        </>
      ) : null}
    </>
  )
}
