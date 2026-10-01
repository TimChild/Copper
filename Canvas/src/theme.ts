/**
 * Light and dark. The host decides with `copperCanvas.theme('light'|'dark')`
 * (it follows Copper's own appearance); until it does, and for 'system', the
 * page follows `prefers-color-scheme`.
 */
export type ThemeMode = 'light' | 'dark' | 'system'

let mode: ThemeMode = 'system'
const listeners = new Set<() => void>()

const media = () =>
  typeof window !== 'undefined' && window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null

export const isDark = () => mode === 'dark' || (mode === 'system' && !!media()?.matches)

function apply() {
  if (typeof document === 'undefined') return
  const dark = isDark()
  const root = document.documentElement
  root.classList.toggle('dark', dark)
  root.style.colorScheme = dark ? 'dark' : 'light'
  root.dataset.theme = dark ? 'dark' : 'light'
  for (const fn of listeners) fn()
}

export function setTheme(next: unknown): ThemeMode {
  mode = next === 'light' || next === 'dark' ? next : 'system'
  apply()
  return mode
}

export const themeMode = () => mode

export function subscribeTheme(fn: () => void) {
  listeners.add(fn)
  return () => {
    listeners.delete(fn)
  }
}

/** Start following the system until the host says otherwise. */
export function installTheme() {
  media()?.addEventListener?.('change', () => {
    if (mode === 'system') apply()
  })
  apply()
}
