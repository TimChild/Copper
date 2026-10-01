/**
 * Other people's cursors, drawn inside the board's transformed layer and
 * counter-scaled so they stay the same size at any zoom. Lifted from the
 * peer block of the wiki app's wiki-canvas-page.tsx and the gliding
 * `transition-transform` of components/agent-cursors.tsx.
 *
 * Reads awareness and the zoom itself, so a cursor moving (anyone's) or a
 * zoom re-renders this and not the board.
 */
import type { Awareness } from 'y-protocols/awareness'
import { usePeers } from '../lib/awareness'
import { useCameraZoom } from '../lib/camera'
import { useBoard } from './board-context'

export function PeerCursors({ awareness }: { awareness: Awareness }) {
  const peers = usePeers(awareness)
  const zoom = useCameraZoom(useBoard().camera)
  return (
    <>
      {peers.map(peer => (
        <div
          key={peer.id}
          data-testid="peer-cursor"
          className="easel-peer"
          style={{
            transform: `translate(${peer.cursor.x}px, ${peer.cursor.y}px) scale(${1 / zoom})`,
          }}
        >
          <svg width="16" height="18" viewBox="0 0 16 18" aria-hidden="true">
            <path
              d="M1 1 L15 9 L8.5 10.5 L5 17 z"
              fill={peer.color}
              stroke="white"
              strokeWidth="1.5"
              strokeLinejoin="round"
            />
          </svg>
          <span
            className="easel-peer-name"
            style={{ backgroundColor: peer.color }}
          >
            {peer.name}
          </span>
        </div>
      ))}
    </>
  )
}
