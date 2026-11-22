import { api } from '../api/client'

export interface PushKeyView { publicKey: string; devices: number }

/** Whether this browser can receive Web Push alerts at all. */
export function pushSupported(): boolean {
  return typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
}

export function base64UrlToBytes(value: string): Uint8Array<ArrayBuffer> {
  const padded = (value + '='.repeat((4 - (value.length % 4)) % 4)).replace(/-/g, '+').replace(/_/g, '/')
  const raw = atob(padded)
  const bytes = new Uint8Array(new ArrayBuffer(raw.length))
  for (let index = 0; index < raw.length; index += 1) bytes[index] = raw.charCodeAt(index)
  return bytes
}

/** Registers the service worker once; safe to call on every load. */
export async function registerServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (!pushSupported()) return null
  try { return await navigator.serviceWorker.register('/sw.js') } catch { return null }
}

export async function currentSubscription(): Promise<PushSubscription | null> {
  if (!pushSupported()) return null
  const registration = await navigator.serviceWorker.getRegistration()
  return (await registration?.pushManager.getSubscription()) ?? null
}

/** Asks permission, subscribes this browser, and tells the server. */
export async function enablePush(label: string): Promise<PushKeyView> {
  const permission = await Notification.requestPermission()
  if (permission !== 'granted') throw new Error('Notifications are blocked for this site. Allow them in your browser settings.')
  const registration = (await registerServiceWorker()) ?? (await navigator.serviceWorker.ready)
  const key = await api<PushKeyView>('push/key')
  const subscription = (await registration.pushManager.getSubscription())
    ?? (await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: base64UrlToBytes(key.publicKey) }))
  return api<PushKeyView>('push/subscribe', { method: 'POST', body: { endpoint: subscription.endpoint, label } })
}

export async function disablePush(): Promise<PushKeyView | null> {
  const subscription = await currentSubscription()
  if (!subscription) return null
  const endpoint = subscription.endpoint
  await subscription.unsubscribe()
  return api<PushKeyView>('push/unsubscribe', { method: 'POST', body: { endpoint } })
}
