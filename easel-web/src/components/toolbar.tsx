/**
 * The floating toolbar at the bottom centre: Select V, Hand H, Sticky S,
 * Frame F, Arrow A, Image (file picker), Laser L. A white hairline card,
 * like Copper's own floating UI.
 */
import { useRef } from 'react'
import { TOOLS, type Tool } from '../lib/canvas-tools'
import { Icon } from './icons'

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

export function Toolbar({
  tool,
  onTool,
  onPickImage,
}: {
  tool: Tool
  onTool: (tool: Tool) => void
  onPickImage: (file: File) => void
}) {
  const fileInput = useRef<HTMLInputElement>(null)
  return (
    <div
      role="toolbar"
      aria-label="Tools"
      className="easel-card easel-toolbar"
      onPointerDown={stop}
    >
      {TOOLS.map((t, i) => (
        <span key={t.tool} className="easel-toolbar-slot">
          {t.tool === 'laser' && (
            <>
              <button
                type="button"
                className="easel-tool"
                aria-label="Image"
                title="Add a picture"
                onClick={() => fileInput.current?.click()}
              >
                <Icon name="image" />
              </button>
              <span className="easel-bar-sep" aria-hidden="true" />
            </>
          )}
          <button
            type="button"
            className="easel-tool"
            aria-label={`${t.label} (${t.key.toUpperCase()})`}
            aria-pressed={tool === t.tool}
            title={`${t.label} (${t.key.toUpperCase()})`}
            onClick={() => onTool(t.tool)}
          >
            <Icon name={t.icon} />
          </button>
          {i === 1 && <span className="easel-bar-sep" aria-hidden="true" />}
        </span>
      ))}
      <input
        ref={fileInput}
        type="file"
        accept="image/*"
        hidden
        onChange={e => {
          const file = e.target.files?.[0]
          e.target.value = ''
          if (file) onPickImage(file)
        }}
      />
    </div>
  )
}

/** Zoom out / level / zoom in / fit, bottom right. */
export function ZoomCluster({
  zoom,
  onZoom,
  onFit,
}: {
  zoom: number
  onZoom: (factor: number) => void
  onFit: () => void
}) {
  return (
    <div
      role="toolbar"
      aria-label="Zoom"
      className="easel-card easel-zoom"
      onPointerDown={stop}
    >
      <button
        type="button"
        className="easel-tool"
        aria-label="Zoom out"
        title="Zoom out (⌘−)"
        onClick={() => onZoom(1 / 1.2)}
      >
        <Icon name="minus" />
      </button>
      <span className="easel-zoom-level" aria-live="polite">
        {Math.round(zoom * 100)}%
      </span>
      <button
        type="button"
        className="easel-tool"
        aria-label="Zoom in"
        title="Zoom in (⌘=)"
        onClick={() => onZoom(1.2)}
      >
        <Icon name="plus" />
      </button>
      <span className="easel-bar-sep" aria-hidden="true" />
      <button
        type="button"
        className="easel-tool"
        aria-label="Fit to screen"
        title="Fit everything"
        onClick={onFit}
      >
        <Icon name="fit" />
      </button>
    </div>
  )
}
