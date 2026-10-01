import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import { installApi } from './api'
import { CanvasApp } from './canvas/components/CanvasApp'
import { VERSION } from './controller'
import { hasNativeHost, postToHost } from './host-bridge'
import { installTheme } from './theme'

installTheme()
installApi()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <CanvasApp />
  </StrictMode>
)

const params = new URLSearchParams(window.location.search)
if (!hasNativeHost() && params.get('dev') === '1') {
  void import('./dev').then(m => m.startDev(params))
} else {
  postToHost({ type: 'ready', version: VERSION })
}
