// Ada's service worker: shows alerts when Ada needs an approval.
// Pushes carry no data. On a push, ask the server (same origin, signed in) what is waiting.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))

self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    let note = { title: 'Ada', body: 'Ada needs your attention.', url: '/' }
    try {
      const response = await fetch('/api/push/latest', { credentials: 'same-origin', headers: { 'Accept-Language': self.navigator.language || 'en' } })
      if (response.ok) note = await response.json()
    } catch { /* keep the generic note */ }
    await self.registration.showNotification(note.title, { body: note.body, icon: '/icon-192.png', badge: '/icon-192.png', tag: 'ada-approval', renotify: true, data: { url: note.url } })
  })())
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || '/'
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const client of windows) {
      if ('focus' in client) {
        await client.focus()
        if ('navigate' in client) await client.navigate(url)
        return
      }
    }
    await self.clients.openWindow(url)
  })())
})
