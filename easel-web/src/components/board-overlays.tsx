/**
 * Small pieces of the board that follow the camera or a gesture every
 * frame, so `EaselPage` does not have to: the marquee and the laser canvas.
 */
import { useCameraView, useCameraZoom } from '../lib/camera'
import { useStore } from '../lib/store'
import { LaserCanvas, type LaserTrails } from '../laser'
import { useBoard } from './board-context'

/** The rubber band, inside the scaled layer with a 1 px screen border. */
export function Marquee() {
  const { camera, marquee } = useBoard()
  const rect = useStore(marquee)
  const zoom = useCameraZoom(camera)
  if (!rect) return null
  return (
    <div
      className="easel-marquee"
      style={{
        transform: `translate(${rect.x}px, ${rect.y}px)`,
        width: rect.w,
        height: rect.h,
        borderWidth: 1 / zoom,
      }}
    />
  )
}

/** `<LaserCanvas>` fed from the camera; it redraws in the frame the view moves. */
export function CameraLaser({ trails }: { trails: LaserTrails }) {
  const view = useCameraView(useBoard().camera)
  return <LaserCanvas trails={trails} view={view} />
}
