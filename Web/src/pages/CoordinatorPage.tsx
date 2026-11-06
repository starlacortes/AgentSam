import { useCallback, useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from 'react'
import { Link } from 'react-router-dom'
import { api, errorMessage } from '../api/client'
import type { ChatLine, ChatSettings, CoordinatorChat } from '../api/chatTypes'
import type { Team } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import { Avatar } from '../components/mission'
import { ErrorBanner, Spinner, formatDate } from '../components/ui'
import '../styles/coordinator.css'

/** The person's main contact: a conversation with a team's coordinator, who can check and launch missions. */
export function CoordinatorPage() {
  const { isAdmin } = useAuth()
  const [teams, setTeams] = useState<Team[] | null>(null)
  const [settings, setSettings] = useState<ChatSettings | null>(null)
  const [chats, setChats] = useState<CoordinatorChat[]>([])
  const [chat, setChat] = useState<CoordinatorChat | null>(null)
  const [draft, setDraft] = useState('')
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const endRef = useRef<HTMLDivElement | null>(null)

  const loadChats = useCallback(async () => {
    const list = await api<CoordinatorChat[]>('chats')
    setChats(list)
    return list
  }, [])

  useEffect(() => {
    Promise.all([api<Team[]>('teams'), api<ChatSettings>('chat-settings'), loadChats()])
      .then(async ([teamList, chatSettings, chatList]) => {
        setTeams(teamList)
        setSettings(chatSettings)
        if (chatList[0]) setChat(await api<CoordinatorChat>(`chats/${chatList[0].id}`))
      })
      .catch((err) => setError(errorMessage(err)))
  }, [loadChats])

  useEffect(() => {
    endRef.current?.scrollIntoView?.({ block: 'end' })
  }, [chat?.lines.length, sending])

  const team = teams?.find((t) => t.id === (chat?.teamID ?? settings?.effectiveTeamID)) ?? null
  const coordinator = team?.agents.find((a) => a.role === 'coordinator') ?? team?.agents[0]

  async function startChat(teamID?: string) {
    setError(null)
    try {
      const created = await api<CoordinatorChat>('chats', { method: 'POST', body: teamID ? { teamID } : {} })
      setChat(created)
      await loadChats()
    } catch (err) {
      setError(errorMessage(err))
    }
  }

  async function openChat(id: string) {
    setError(null)
    try {
      setChat(await api<CoordinatorChat>(`chats/${id}`))
    } catch (err) {
      setError(errorMessage(err))
    }
  }

  async function send(event?: FormEvent) {
    event?.preventDefault()
    const text = draft.trim()
    if (!text || sending) return
    setSending(true)
    setError(null)
    try {
      let current = chat
      if (!current) {
        current = await api<CoordinatorChat>('chats', { method: 'POST', body: {} })
      }
      // Show the person's line right away while the coordinator thinks.
      const optimistic: ChatLine = { id: `local-${Date.now()}`, kind: 'user', text, createdAt: new Date().toISOString() }
      setChat({ ...current, lines: [...current.lines, optimistic] })
      setDraft('')
      const updated = await api<CoordinatorChat>(`chats/${current.id}/messages`, { method: 'POST', body: { text } })
      setChat(updated)
      await loadChats()
    } catch (err) {
      setError(errorMessage(err))
      setDraft(text)
      if (chat) setChat(await api<CoordinatorChat>(`chats/${chat.id}`).catch(() => chat))
    } finally {
      setSending(false)
    }
  }

  async function resolve(approve: boolean) {
    if (!chat) return
    setSending(true)
    setError(null)
    try {
      setChat(await api<CoordinatorChat>(`chats/${chat.id}/confirm`, { method: 'POST', body: { approve } }))
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setSending(false)
    }
  }

  async function makeDefault(teamID: string) {
    try {
      setSettings(await api<ChatSettings>('chat-settings', { method: 'PUT', body: { defaultTeamID: teamID } }))
    } catch (err) {
      setError(errorMessage(err))
    }
  }

  function onKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      void send()
    }
  }

  if (!teams) {
    return (
      <>
        <ErrorBanner message={error} />
        <Spinner />
      </>
    )
  }

  if (teams.length === 0) {
    return (
      <div className="card empty">
        <p style={{ marginBottom: 14 }}>Hire a team first, and its coordinator becomes your contact here.</p>
        <Link className="btn" to="/templates">
          Hire a team
        </Link>
      </div>
    )
  }

  return (
    <div className="coord">
      <aside className="coord-side" aria-label="Conversations">
        <button type="button" className="btn small" onClick={() => void startChat(team?.id)}>
          New conversation
        </button>
        <ul className="coord-chats">
          {chats.map((c) => (
            <li key={c.id}>
              <button type="button" className={c.id === chat?.id ? 'coord-chat sel' : 'coord-chat'} onClick={() => void openChat(c.id)}>
                <span className="coord-chat-title">{c.title || 'New conversation'}</span>
                <span className="dim">
                  {c.teamName} · {formatDate(c.updatedAt)}
                </span>
              </button>
            </li>
          ))}
        </ul>
      </aside>

      <section className="coord-main">
        <div className="coord-head">
          {coordinator ? <Avatar name={coordinator.name} role="coordinator" size={40} /> : null}
          <div>
            <div className="kicker">Your coordinator</div>
            <h1 className="coord-name">
              {coordinator?.name ?? 'Coordinator'} <span className="muted">· {team?.name}</span>
            </h1>
          </div>
          <span className="spacer" />
          <label className="coord-team">
            <span className="dim">Talk to</span>
            <select
              className="select"
              value={team?.id ?? ''}
              onChange={(e) => void startChat(e.target.value)}
              aria-label="Team to talk to"
            >
              {teams.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.emoji} {t.name}
                  {t.id === settings?.effectiveTeamID ? ' (default)' : ''}
                </option>
              ))}
            </select>
          </label>
          {isAdmin && team && team.id !== settings?.effectiveTeamID ? (
            <button type="button" className="btn ghost small" onClick={() => void makeDefault(team.id)}>
              Make default
            </button>
          ) : null}
        </div>

        <ErrorBanner message={error} />

        <div className="coord-log" aria-live="polite">
          {!chat || chat.lines.length === 0 ? (
            <div className="coord-empty muted">
              Ask {coordinator?.name ?? 'your coordinator'} what the team is working on, for a summary of a report, or to start a new
              mission.
            </div>
          ) : (
            chat.lines.map((line) => <Line key={line.id} line={line} name={coordinator?.name ?? 'Coordinator'} />)
          )}
          {sending ? (
            <div className="coord-line coordinator">
              <Spinner label={`${coordinator?.name ?? 'Coordinator'} is thinking`} />
            </div>
          ) : null}
          <div ref={endRef} />
        </div>

        {chat?.pendingAction ? (
          <div className="coord-confirm" role="group" aria-label="Confirm action">
            <div>
              <b>{chat.pendingAction.kind === 'startMission' ? `Start a mission on ${chat.pendingAction.teamName ?? 'the team'}?` : 'Stop this mission?'}</b>
              <div className="muted coord-confirm-text">{chat.pendingAction.summary}</div>
            </div>
            <div className="row">
              <button type="button" className="btn small" disabled={sending} onClick={() => void resolve(true)}>
                {chat.pendingAction.kind === 'startMission' ? 'Start it' : 'Stop it'}
              </button>
              <button type="button" className="btn ghost small" disabled={sending} onClick={() => void resolve(false)}>
                Cancel
              </button>
            </div>
          </div>
        ) : null}

        <form className="coord-compose" onSubmit={(e) => void send(e)}>
          <textarea
            className="textarea"
            rows={2}
            placeholder={`Message ${coordinator?.name ?? 'your coordinator'}`}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKeyDown}
            maxLength={8000}
            aria-label="Message"
          />
          <button type="submit" className="btn" disabled={sending || !draft.trim()}>
            Send
          </button>
        </form>
        {chat && chat.totalCostUSD > 0 ? <div className="hint">Conversation cost about ${chat.totalCostUSD.toFixed(4)}</div> : null}
      </section>
    </div>
  )
}

function Line({ line, name }: { line: ChatLine; name: string }) {
  if (line.kind === 'action' || line.kind === 'error') {
    return (
      <div className={`coord-note ${line.kind}`}>
        {line.text}
        {line.missionID ? (
          <>
            {' · '}
            <Link to={`/missions/${line.missionID}`}>Open mission</Link>
          </>
        ) : null}
      </div>
    )
  }
  return (
    <div className={`coord-line ${line.kind}`}>
      <div className="coord-who">{line.kind === 'user' ? 'You' : name}</div>
      <div className="coord-text">{line.text}</div>
    </div>
  )
}
