import { useEffect, useState, type ReactNode } from 'react'
import { Navigate, NavLink, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import type { VoiceInfo } from '../api/chatTypes'
import type { ConnectorStatus, GuideState, WorkspaceKnowledge, WorkspaceMemory } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { ConnectorCard, HostAccessPanel, KnowledgePanel, MemoryPanel } from '../components/coordinator/WorkspacePanels'
import { Icon, type IconName } from '../components/coordinator/Icon'
import { LanguageToggle } from '../components/Layout'
import { VoiceSettingsPanel } from '../components/VoiceSettingsPanel'
import { ErrorBanner, Spinner } from '../components/ui'
import { useI18n } from '../i18n'
import { useDocumentTitle } from '../lib/useDocumentTitle'
import { AccountPage } from './AccountPage'
import { PeoplePage } from './PeoplePage'
import { ProvidersPage } from './ProvidersPage'
import { PermissionsPanel } from '../components/PermissionsPanel'

export type SettingsSection = 'connections' | 'permissions' | 'memory' | 'preferences' | 'account' | 'providers' | 'people' | 'folders'

interface SectionLink { id: SettingsSection; label: string; icon: IconName; adminOnly?: boolean }

/** Every setting in one place: one list of sections on the left (a row of chips on phones). */
export function SettingsPage() {
  const { section } = useParams()
  const { t } = useI18n()
  const { isAdmin, signOut } = useAuth()
  const all: SectionLink[] = [
    { id: 'connections', label: t('Connections'), icon: 'plug' },
    { id: 'permissions', label: t('What Ada can do alone'), icon: 'shield' },
    { id: 'memory', label: t('Memory & knowledge'), icon: 'memory' },
    { id: 'preferences', label: t('Voice & language'), icon: 'mic' },
    { id: 'account', label: t('Account'), icon: 'users' },
    { id: 'providers', label: t('Model providers'), icon: 'spark', adminOnly: true },
    { id: 'people', label: t('People'), icon: 'users', adminOnly: true },
    { id: 'folders', label: t('Folder access'), icon: 'folder', adminOnly: true },
  ]
  const sections = all.filter((item) => isAdmin || !item.adminOnly)
  const current = sections.find((item) => item.id === section)
  useDocumentTitle(current ? `${current.label} · ${t('Settings')}` : t('Settings'))
  if (!current) return <Navigate to="/settings/connections" replace />

  return (
    <div className="settings">
      <nav className="settings-nav" aria-label={t('Settings')}>
        <h1 className="settings-title">{t('Settings')}</h1>
        {sections.map((item) => (
          <NavLink key={item.id} to={`/settings/${item.id}`} className={({ isActive }) => `settings-link ${isActive ? 'active' : ''}`}>
            <Icon name={item.icon} size={15} />
            <span>{item.label}</span>
          </NavLink>
        ))}
        <button className="settings-link settings-signout" onClick={() => void signOut()}>
          <span>{t('Sign out')}</span>
        </button>
      </nav>
      <section className="settings-body">
        {current.id === 'connections' ? <ConnectionsSettings /> : null}
        {current.id === 'permissions' ? <SectionHead title={t('What Ada can do alone')} lede={t('Choose which actions Ada may take without asking, and the limits that keep them small.')}><PermissionsPanel /></SectionHead> : null}
        {current.id === 'memory' ? <MemorySettings /> : null}
        {current.id === 'preferences' ? <PreferenceSettings /> : null}
        {current.id === 'account' ? <AccountPage /> : null}
        {current.id === 'providers' ? <ProvidersPage /> : null}
        {current.id === 'people' ? <PeoplePage /> : null}
        {current.id === 'folders' ? <SectionHead title={t('Folder access')} lede={t('Folders on the server that Ada may read, and optionally write.')}><HostAccessPanel /></SectionHead> : null}
      </section>
    </div>
  )
}

function SectionHead({ title, lede, children }: { title: string; lede: string; children: ReactNode }) {
  return (
    <>
      <div className="page-head">
        <div>
          <h1>{title}</h1>
          <p className="lede">{lede}</p>
        </div>
      </div>
      {children}
    </>
  )
}

function ConnectionsSettings() {
  const { t } = useI18n()
  const [params, setParams] = useSearchParams()
  const [connectors, setConnectors] = useState<ConnectorStatus[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => { void api<ConnectorStatus[]>('connectors').then(setConnectors).catch((err) => setError(errorMessage(err))) }, [])
  // Google sends people back here after they sign in.
  const connectedName = connectors?.find((item) => item.id === params.get('connected'))?.name
  return (
    <SectionHead title={t('Connections')} lede={t('Give Ada access to the services you choose.')}>
      <ErrorBanner message={error} />
      {connectedName ? <div className="notice row"><span style={{ flex: 1 }}>{t('{name} is connected.', { name: connectedName })}</span><button className="pill" onClick={() => setParams({})}>{t('Dismiss')}</button></div> : null}
      {!connectors ? <Spinner /> : <div className="settings-cards">{connectors.map((connector) => <ConnectorCard key={connector.id} connector={connector} onChange={(updated) => setConnectors((list) => (list ?? []).map((item) => item.id === updated.id ? updated : item))} />)}</div>}
      <div className="co-safety-note"><Icon name="shield" /><p>{t('External writes need your one-use approval unless a rule under What Ada can do alone allows them. Connector permissions still apply. Read tools do not need approval.')}</p></div>
    </SectionHead>
  )
}

function MemorySettings() {
  const { t } = useI18n()
  const [memory, setMemory] = useState<WorkspaceMemory | null>(null)
  const [knowledge, setKnowledge] = useState<WorkspaceKnowledge | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    void api<WorkspaceMemory>('workspace/memory').then(setMemory).catch((err) => setError(errorMessage(err)))
    void api<WorkspaceKnowledge>('workspace/knowledge').then(setKnowledge).catch((err) => setError(errorMessage(err)))
  }, [])
  return (
    <SectionHead title={t('Memory & knowledge')} lede={t('What Ada remembers across your chats, and what she knows about your workspace.')}>
      <ErrorBanner message={error} />
      <MemoryPanel memory={memory} onChange={setMemory} />
      <KnowledgePanel knowledge={knowledge} onChange={setKnowledge} />
    </SectionHead>
  )
}

function PreferenceSettings() {
  const { t } = useI18n()
  const { isAdmin } = useAuth()
  const navigate = useNavigate()
  const [voiceInfo, setVoiceInfo] = useState<VoiceInfo | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    if (!isAdmin) return
    void api<VoiceInfo>('voice').then(setVoiceInfo).catch((err) => setError(errorMessage(err)))
  }, [isAdmin])
  const restartGuide = async () => {
    setBusy(true); setError(null)
    try {
      await api<GuideState>('workspace/guide', { method: 'PATCH', body: { completed: false } })
      navigate('/?guide=1')
    } catch (err) { setError(errorMessage(err)); setBusy(false) }
  }
  return (
    <SectionHead title={t('Voice & language')} lede={t('Simple controls, without resetting your work.')}>
      <div className="co-setting-card">
        <div className="co-setting-row"><span>{t('Language')}</span><LanguageToggle /></div>
        {voiceInfo ? <VoiceSettingsPanel info={voiceInfo} onSaved={setVoiceInfo} onError={setError} /> : null}
      </div>
      <div className="co-guide-reset">
        <h3>{t('A quick guide, whenever you need it')}</h3>
        <p>{t('Three short steps explain chat, how Ada gets help, and connections. Restarting changes only the guide—not your chats, providers, connections, or memory.')}</p>
        <button className="co-secondary-button" disabled={busy} onClick={() => void restartGuide()}><Icon name="info" size={14} />{t('Restart the guide')}</button>
      </div>
      <ErrorBanner message={error} />
    </SectionHead>
  )
}
