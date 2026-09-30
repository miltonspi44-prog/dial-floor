// Dial Floor: lets the Floor tab raise system notifications (E4). Phones only
// show them through a service worker. No caching, no push, no fetch handler:
// it never touches how the app loads.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))
self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((tabs) => {
    const tab = tabs.find((t) => t.url.includes('/floor')) ?? tabs[0]
    return tab ? tab.focus() : self.clients.openWindow('/floor')
  }))
})
