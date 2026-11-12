import { useEffect, useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { useI18n, type Lang } from '../i18n'
import { Logo } from './ui'

interface NavItem {
  to: string
  label: string
  end?: boolean
}

/** English/Spanish switch for the top right of the toolbar. */
export function LanguageToggle() {
  const { lang, setLang, t } = useI18n()
  const pill = (code: Lang) => (lang === code ? 'pill active' : 'pill')
  return (
    <div className="lang-toggle" role="group" aria-label={t('Language')}>
      <button className={pill('en')} aria-pressed={lang === 'en'} onClick={() => setLang('en')}>
        EN
      </button>
      <button className={pill('es')} aria-pressed={lang === 'es'} onClick={() => setLang('es')}>
        ES
      </button>
    </div>
  )
}

export function Layout() {
  const { me, isAdmin, signOut } = useAuth()
  const { t } = useI18n()
  const location = useLocation()
  const [moreOpen, setMoreOpen] = useState(false)
  const pill = ({ isActive }: { isActive: boolean }) => (isActive ? 'pill active' : 'pill')

  const primary: NavItem[] = [
    { to: '/', label: t('Chat'), end: true },
    { to: '/teams', label: t('Teams') },
    { to: '/templates', label: t('Library') },
  ]
  const secondary: NavItem[] = [
    { to: '/missions', label: t('History') },
    ...(isAdmin ? [{ to: '/settings', label: t('Providers') }] : []),
    ...(isAdmin ? [{ to: '/people', label: t('People') }] : []),
    { to: '/account', label: t('Account') },
  ]

  // Close the phone menu whenever the page changes.
  useEffect(() => setMoreOpen(false), [location.pathname])

  const moreActive = secondary.some((item) => location.pathname.startsWith(item.to))

  if (location.pathname === '/' || location.pathname.startsWith('/chats/')) return <Outlet />

  return (
    <>
      <header className="topbar">
        <NavLink to="/" className="logo" aria-label={t('AgentSam home')}>
          <Logo />
        </NavLink>
        <nav className="nav" aria-label={t('Main')}>
          {[...primary, ...secondary].map((item) => (
            <NavLink key={item.to} to={item.to} end={item.end} className={pill}>
              {item.label}
            </NavLink>
          ))}
        </nav>
        <span className="whoami">
          {me?.name} · {me?.role ? t(me.role) : ''}
        </span>
        <LanguageToggle />
        <button className="pill signout" onClick={() => void signOut()}>
          {t('Sign out')}
        </button>
      </header>
      <main className="page">
        <Outlet />
      </main>

      {/* Phone navigation: the three main sections plus a "More" sheet for everything else. */}
      <nav className="tabbar" aria-label={t('Main')}>
        {primary.map((item) => (
          <NavLink key={item.to} to={item.to} end={item.end} className={({ isActive }) => (isActive ? 'tab active' : 'tab')}>
            {item.label}
          </NavLink>
        ))}
        <button className={moreActive || moreOpen ? 'tab active' : 'tab'} aria-expanded={moreOpen} onClick={() => setMoreOpen((open) => !open)}>
          {t('More')}
        </button>
      </nav>
      {moreOpen ? (
        <>
          <div className="sheet-backdrop" onClick={() => setMoreOpen(false)} />
          <div className="sheet" role="menu">
            <div className="sheet-who mono">
              {me?.name} · {me?.role ? t(me.role) : ''}
            </div>
            {secondary.map((item) => (
              <NavLink key={item.to} to={item.to} role="menuitem" className={({ isActive }) => (isActive ? 'sheet-item active' : 'sheet-item')}>
                {item.label}
              </NavLink>
            ))}
            <div className="sheet-item">
              <LanguageToggle />
            </div>
            <button className="sheet-item danger" role="menuitem" onClick={() => void signOut()}>
              {t('Sign out')}
            </button>
          </div>
        </>
      ) : null}
    </>
  )
}
