import { useAuth } from '../auth/AuthContext'

export function HomePage() {
  const { me } = useAuth()
  return (
    <>
      <div className="page-head">
        <div>
          <div className="kicker">Missions</div>
          <h1>Hi {me?.name}.</h1>
        </div>
      </div>
      <div className="card empty">
        <p>Mission launch and the live war room are coming in the next update.</p>
      </div>
    </>
  )
}
