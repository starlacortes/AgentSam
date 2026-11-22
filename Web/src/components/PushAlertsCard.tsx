import { useEffect, useState } from 'react'
import { api, errorMessage } from '../api/client'
import { useI18n } from '../i18n'
import { currentSubscription, disablePush, enablePush, pushSupported, type PushKeyView } from '../lib/push'
import { Icon } from './coordinator/Icon'
import { ErrorBanner } from './ui'

/** Turns phone and browser alerts for approval requests on or off for this device. */
export function PushAlertsCard() {
  const { t } = useI18n()
  const [on, setOn] = useState<boolean | null>(null)
  const [devices, setDevices] = useState(0)
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const supported = pushSupported()

  useEffect(() => {
    if (!supported) return
    void currentSubscription().then((subscription) => setOn(Boolean(subscription))).catch(() => setOn(false))
    void api<PushKeyView>('push/key').then((key) => setDevices(key.devices)).catch(() => {})
  }, [supported])

  const run = async (work: () => Promise<void>) => {
    setBusy(true)
    setError(null)
    setNote(null)
    try { await work() } catch (err) { setError(errorMessage(err)) } finally { setBusy(false) }
  }
  const turnOn = () => run(async () => {
    const view = await enablePush(navigator.userAgent.includes('Mobile') ? 'Phone' : 'Computer')
    setDevices(view.devices)
    setOn(true)
  })
  const turnOff = () => run(async () => {
    const view = await disablePush()
    if (view) setDevices(view.devices)
    setOn(false)
  })
  const test = () => run(async () => {
    const result = await api<{ delivered: number }>('push/test', { method: 'POST' })
    setNote(result.delivered ? t('Test alert sent to {count} device(s).', { count: result.delivered }) : t('No device accepted the alert. Turn alerts off and on again on this device.'))
  })

  return <div className="co-setting-card push-alerts">
    <div className="co-setting-row">
      <div>
        <b>{t('Approval alerts')}</b>
        <p>{supported
          ? t('Get a notification on this device when Ada needs your approval. On an iPhone, add Ada to the home screen first.')
          : t('This browser cannot show alerts. On an iPhone, add Ada to the home screen and open it from there.')}</p>
        {devices ? <p>{t('{count} device(s) get alerts.', { count: devices })}</p> : null}
      </div>
      {supported ? <div className="push-actions">
        {on ? <>
          <button className="co-secondary-button" disabled={busy} onClick={() => void test()}><Icon name="check" size={14} />{t('Send a test')}</button>
          <button className="co-secondary-button" disabled={busy} onClick={() => void turnOff()}>{t('Turn off here')}</button>
        </> : <button className="co-primary-button" disabled={busy || on === null} onClick={() => void turnOn()}><Icon name="phone" size={14} />{t('Turn on alerts here')}</button>}
      </div> : null}
    </div>
    {note ? <p className="co-panel-note">{note}</p> : null}
    <ErrorBanner message={error} />
  </div>
}
