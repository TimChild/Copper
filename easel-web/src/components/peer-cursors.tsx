/**
 * Other people's cursors, drawn inside the board's transformed layer and
 * counter-scaled so they stay the same size at any zoom. Lifted from the
 * peer block of the wiki app's wiki-canvas-page.tsx and the gliding
 * `transition-transform` of components/agent-cursors.tsx.
 */
import type { Peer } from '../lib/awareness'

export function PeerCursors({
  peers,
  zoom,
}: {
  peers: readonly Peer[]
  zoom: number
}) {
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
