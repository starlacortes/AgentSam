import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { AuthProvider } from './auth/AuthContext'
import { I18nProvider } from './i18n'
import { App } from './App'
import { DialogProvider } from './components/ConfirmDialog'
import { registerServiceWorker } from './lib/push'
import './styles/theme.css'
import './styles/coordinator.css'
import './styles/orb.css'

// The service worker only shows approval alerts; it does not cache the app.
void registerServiceWorker()

const root = document.getElementById('root')
if (!root) throw new Error('Missing #root')

createRoot(root).render(
  <StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <I18nProvider>
          <DialogProvider>
            <App />
          </DialogProvider>
        </I18nProvider>
      </AuthProvider>
    </BrowserRouter>
  </StrictMode>,
)
