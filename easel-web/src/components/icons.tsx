/** Inline SVG icons, 16px, stroked in currentColor. No icon fonts, nothing fetched. */
import type { SVGProps } from 'react'
import type { IconName } from '../lib/canvas-tools'

export type GlyphName =
  | IconName
  | 'trash'
  | 'eraser'
  | 'plus'
  | 'minus'
  | 'fit'
  | 'undo'
  | 'redo'

const PATHS: Record<GlyphName, string | string[]> = {
  select: 'M4 2.5 L13.5 8.5 L9 9.5 L6.5 13.5 Z',
  hand: [
    'M6 8.5V3.5a1 1 0 0 1 2 0v4.5',
    'M8 7.5V2.75a1 1 0 0 1 2 0V8',
    'M10 7.75V3.5a1 1 0 0 1 2 0v5.75',
    'M12 9.25V5.5a1 1 0 0 1 2 0v4.5c0 2.5-1.8 4.5-4.5 4.5H9.1c-1.2 0-2.3-.55-3-1.5L3.1 9.3a1 1 0 0 1 1.6-1.2L6 10',
  ],
  sticky: [
    'M3 3h10v6l-4 4H3z',
    'M9 13V9h4',
  ],
  frame: [
    'M2.5 5.5h11v8h-11z',
    'M2.5 5.5l2-3h7l2 3',
  ],
  arrow: ['M2.5 13.5L13 3', 'M7.5 3H13v5.5'],
  image: [
    'M2.5 3.5h11v9h-11z',
    'M2.5 11l3.5-3.5 2.5 2.5 2-2 3 3',
    'M10.5 6.5h.01',
  ],
  laser: [
    'M3 13L9.5 6.5',
    'M11.5 4.5l.01-.01',
    'M11.5 1.5v1.5',
    'M14.5 4.5H13',
    'M13.6 2.4l-1.1 1.1',
    'M13.6 6.6l-1.1-1.1',
    'M9.4 2.4l1.1 1.1',
  ],
  trash: ['M3 4.5h10', 'M6.5 4.5V3h3v1.5', 'M4.5 4.5l.6 8.5h5.8l.6-8.5', 'M7 7v4', 'M9 7v4'],
  eraser: ['M9.5 3.5l3 3-6 6H4l-1.5-1.5 7-7.5z', 'M6 12.5h7.5', 'M5.5 7.5l3 3'],
  plus: ['M8 3v10', 'M3 8h10'],
  minus: ['M3 8h10'],
  fit: ['M3 6V3h3', 'M13 6V3h-3', 'M3 10v3h3', 'M13 10v3h-3'],
  undo: ['M6 4.5L3 7.5l3 3', 'M3 7.5h6.5a3 3 0 1 1 0 6H8'],
  redo: ['M10 4.5l3 3-3 3', 'M13 7.5H6.5a3 3 0 1 0 0 6H8'],
}

export function Icon({
  name,
  size = 16,
  ...rest
}: { name: GlyphName; size?: number } & SVGProps<SVGSVGElement>) {
  const d = PATHS[name]
  const filled = name === 'select'
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill={filled ? 'currentColor' : 'none'}
      stroke="currentColor"
      strokeWidth={filled ? 1.2 : 1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {(Array.isArray(d) ? d : [d]).map((path, i) => (
        <path key={i} d={path} />
      ))}
    </svg>
  )
}
