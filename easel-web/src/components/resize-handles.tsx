/**
 * Resize affordances around the selected sticky or frame. Lifted from
 * the wiki app's apps/web/src/modules/wiki/components/resize-handles.tsx with
 * class names moved to app.css.
 */
import type { CSSProperties, PointerEvent as ReactPointerEvent } from 'react'
import type { Box } from '../lib/canvas-geometry'
import {
  CORNER_HANDLES,
  EDGE_HANDLES,
  HANDLE_CURSOR,
  type Handle,
} from '../lib/canvas-resize'

/** On-screen sizes in px; divided by zoom so they never scale with the board. */
const CORNER_PX = 10
const EDGE_PX = 8
const BORDER_PX = 1.5

const at = (handle: Handle) => ({
  x: handle.includes('w') ? '0%' : handle.includes('e') ? '100%' : '50%',
  y: handle.includes('n') ? '0%' : handle.includes('s') ? '100%' : '50%',
})

export function ResizeHandles({
  box,
  zoom,
  onStart,
}: {
  box: Box
  zoom: number
  onStart: (handle: Handle, e: ReactPointerEvent<HTMLElement>) => void
}) {
  const corner = CORNER_PX / zoom
  const edge = EDGE_PX / zoom
  const handleProps = (handle: Handle, style: CSSProperties) => ({
    'data-handle': handle,
    title: 'Drag to resize',
    style: { ...style, cursor: HANDLE_CURSOR[handle] },
    onPointerDown: (e: ReactPointerEvent<HTMLElement>) => onStart(handle, e),
  })
  return (
    <div
      className="easel-handles"
      style={{
        width: box.w,
        height: box.h,
        transform: `translate(${box.x}px, ${box.y}px)`,
      }}
    >
      {EDGE_HANDLES.map(handle => {
        const vertical = handle === 'e' || handle === 'w'
        const { x, y } = at(handle)
        return (
          <div
            key={handle}
            className="easel-handle"
            {...handleProps(
              handle,
              vertical
                ? {
                    left: x,
                    top: corner / 2,
                    bottom: corner / 2,
                    width: edge,
                    transform: 'translateX(-50%)',
                  }
                : {
                    top: y,
                    left: corner / 2,
                    right: corner / 2,
                    height: edge,
                    transform: 'translateY(-50%)',
                  }
            )}
          />
        )
      })}
      {CORNER_HANDLES.map(handle => {
        const { x, y } = at(handle)
        return (
          <div
            key={handle}
            className="easel-handle easel-handle-corner"
            {...handleProps(handle, {
              left: x,
              top: y,
              width: corner,
              height: corner,
              borderWidth: BORDER_PX / zoom,
              borderRadius: 2 / zoom,
              transform: 'translate(-50%, -50%)',
            })}
          />
        )
      })}
    </div>
  )
}
