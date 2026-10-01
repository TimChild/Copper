/**
 * Shape colours. Named colours resolve to CSS variables (light and dark sets
 * live in index.css), so a theme switch repaints the board without touching
 * the doc. `#hex` colours are used as given, with an ink picked for contrast.
 */
import { SHAPE_COLORS, isNamedColor, type NamedColor, type ShapeColor } from './types'

export const COLOR_LABEL: Record<NamedColor, string> = {
  yellow: 'Yellow',
  pink: 'Pink',
  blue: 'Blue',
  green: 'Green',
  purple: 'Purple',
  gray: 'Gray',
  white: 'White',
}

export { SHAPE_COLORS }

/** Paper (fill) of a sticky or frame header. */
export const paperOf = (c: ShapeColor) => (isNamedColor(c) ? `var(--paper-${c})` : c)

/** Ink on that paper. */
export const inkOn = (c: ShapeColor) => (isNamedColor(c) ? `var(--ink-on-${c})` : contrastInk(c))

/** Strong tone of a colour: arrows, text shapes, accents. */
export const strokeOf = (c: ShapeColor) => (isNamedColor(c) ? `var(--stroke-${c})` : c)

/** Swatch dot in pickers. */
export const swatchOf = (c: ShapeColor) => (isNamedColor(c) ? `var(--swatch-${c})` : c)

function hexRgb(hex: string): [number, number, number] | null {
  let h = hex.replace('#', '')
  if (h.length === 3 || h.length === 4)
    h = h
      .slice(0, 3)
      .split('')
      .map(c => c + c)
      .join('')
  if (h.length === 8) h = h.slice(0, 6)
  if (h.length !== 6) return null
  const n = Number.parseInt(h, 16)
  if (!Number.isFinite(n)) return null
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

/** Relative luminance (WCAG) of a hex colour; 1 when unreadable. */
export function luminance(hex: string): number {
  const rgb = hexRgb(hex)
  if (!rgb) return 1
  const [r, g, b] = rgb.map(v => {
    const c = v / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  }) as [number, number, number]
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/** Near-black on light colours, near-white on dark ones. */
export const contrastInk = (hex: string) => (luminance(hex) > 0.36 ? '#1d1d1f' : '#f8f8f7')

/** A stable hue for someone without a colour. */
export function hueOf(seed: string): number {
  let hash = 0
  for (let i = 0; i < seed.length; i++) hash = (hash * 31 + seed.charCodeAt(i)) | 0
  return Math.abs(hash) % 360
}

export const colorFor = (seed: string) => `hsl(${hueOf(seed)} 62% 48%)`

/** Initials for an avatar: "Ada Lovelace" → "AL", "claude" → "C". */
export function initials(name: string): string {
  const parts = name.trim().split(/[\s._-]+/).filter(Boolean)
  if (parts.length === 0) return '?'
  if (parts.length === 1) return parts[0]!.slice(0, 1).toUpperCase()
  return (parts[0]!.slice(0, 1) + parts[parts.length - 1]!.slice(0, 1)).toUpperCase()
}
