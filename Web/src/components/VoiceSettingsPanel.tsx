import { useState } from 'react'
import { api, errorMessage } from '../api/client'
import type { VoiceInfo, VoiceSettings } from '../api/chatTypes'

/** Admin-only: which providers listen and speak for the coordinator. Empty means automatic. */
export function VoiceSettingsPanel({ info, onSaved, onError }: { info: VoiceInfo; onSaved: (info: VoiceInfo) => void; onError: (message: string) => void }) {
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const { stt, tts } = info.setup
  const listeners = info.providers.filter((p) => p.canTranscribe)
  const speakers = info.providers.filter((p) => p.canSpeak)

  async function save(change: Partial<VoiceSettings>) {
    setBusy(true)
    try {
      const next: VoiceSettings = { ...info.settings, ...change }
      onSaved(await api<VoiceInfo>('voice', { method: 'PUT', body: next }))
    } catch (err) {
      onError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="voice-panel">
      <button type="button" className="voice-panel-toggle" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        <span>Voice</span>
        <span className="dim">{open ? 'Hide' : 'Settings'}</span>
      </button>
      <div className="voice-summary dim">
        {stt ? `Listens with ${stt.providerName}` : 'No speech-to-text key'}
        {' · '}
        {tts ? `speaks with ${tts.providerName} (${tts.voice})` : 'speaks with the browser voice'}
      </div>
      {open ? (
        <div className="voice-fields">
          <label className="field">
            <span>Listen with</span>
            <select
              className="select"
              disabled={busy}
              value={info.settings.sttProviderID ?? ''}
              onChange={(e) => void save({ sttProviderID: e.target.value || undefined, sttModel: undefined })}
            >
              <option value="">Automatic</option>
              {listeners.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Speak with</span>
            <select
              className="select"
              disabled={busy}
              value={info.settings.ttsProviderID ?? ''}
              onChange={(e) => void save({ ttsProviderID: e.target.value || undefined, ttsModel: undefined })}
            >
              <option value="">Automatic</option>
              {speakers.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
              <option value="none">Browser voice (free)</option>
            </select>
          </label>
          {tts ? (
            <label className="field">
              <span>Voice</span>
              <select className="select" disabled={busy} value={tts.voice ?? ''} onChange={(e) => void save({ ttsVoice: e.target.value })}>
                {info.voices.map((v) => (
                  <option key={v} value={v}>
                    {v}
                  </option>
                ))}
              </select>
            </label>
          ) : null}
          {listeners.length === 0 ? <small className="hint">Add an OpenAI or Groq key under Providers to talk by voice.</small> : null}
        </div>
      ) : null}
    </div>
  )
}
